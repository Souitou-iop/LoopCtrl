package main

import (
	"bufio"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
)

const (
	enrollRate     = 20 // unauthenticated enrollment calls per address per minute
	authRate       = 60 // device sign-ins per address per minute
	pairRate       = 10 // pairing requests to one phone per address per minute
	maxJSONBody    = 64 * 1024
	maxProxiedBody = 16 * 1024 * 1024
)

var eventLog bool

type config struct {
	deviceDomain string // "r.example.com": phones at <slug>.r.example.com
	pathRouting  bool   // phones at <public server>/d/<slug>/
	publicScheme string
	trustedHosts []netip.Prefix
}

type relay struct {
	st  *state
	cfg config
}

// MARK: routing

func (rl *relay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if rl.cfg.deviceDomain != "" {
		host := strings.ToLower(r.Host)
		if slug, ok := strings.CutSuffix(host, "."+rl.cfg.deviceDomain); ok {
			if !slugPattern.MatchString(slug) {
				http.NotFound(w, r)
				return
			}
			rl.forward(w, r, slug, r.URL.RequestURI())
			return
		}
	}
	if rl.cfg.pathRouting {
		if rest, ok := strings.CutPrefix(r.URL.EscapedPath(), "/d/"); ok {
			slug, tail, found := strings.Cut(rest, "/")
			if !slugPattern.MatchString(slug) {
				http.NotFound(w, r)
				return
			}
			if !found {
				// Relative, so a path prefix in front of the relay survives
				// (http.Redirect would make it absolute).
				w.Header().Set("Location", slug+"/remote")
				w.WriteHeader(http.StatusFound)
				return
			}
			target := "/" + tail
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			rl.forward(w, r, slug, target)
			return
		}
	}
	rl.api(w, r)
}

func (rl *relay) api(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/healthz":
		writeJSON(w, 200, map[string]any{"ok": true, "api": apiVersion, "server": rl.st.server, "tunnel": 1})
	case r.Method == http.MethodGet && r.URL.Path == "/v1/admin/devices":
		if rl.requireOperator(w, r) {
			writeJSON(w, 200, map[string]any{"devices": rl.st.listDevices(rl.publicURL)})
		}
	case r.Method == http.MethodPost && r.URL.Path == "/v1/admin/enrollments":
		rl.createEnrollment(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/enroll/preview":
		rl.preview(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/enroll/redeem":
		rl.redeem(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/device/challenge":
		rl.challenge(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/device/session":
		rl.session(w, r)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/device/tunnel":
		rl.tunnel(w, r)
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/devices/"):
		rl.unbind(w, r, strings.TrimPrefix(r.URL.Path, "/v1/devices/"))
	default:
		writeJSON(w, 404, map[string]any{"error": "not_found"})
	}
}

func (rl *relay) publicURL(d *device) string {
	if rl.cfg.deviceDomain != "" {
		return fmt.Sprintf("%s://%s.%s/", rl.cfg.publicScheme, d.Slug, rl.cfg.deviceDomain)
	}
	if rl.cfg.pathRouting {
		return fmt.Sprintf("%s://%s/d/%s/", rl.cfg.publicScheme, rl.st.server, d.Slug)
	}
	return ""
}

// MARK: enrollment and sign-in

func (rl *relay) createEnrollment(w http.ResponseWriter, r *http.Request) {
	if !rl.requireOperator(w, r) {
		return
	}
	var body struct {
		Operators    []operator `json:"operators"`
		Organization *string    `json:"organization"`
		Capabilities []string   `json:"capabilities"`
		ExpiresIn    *float64   `json:"expires_in"`
	}
	if !readJSON(w, r, &body, false) {
		return
	}
	ops := make([]operator, 0, len(body.Operators))
	for _, op := range body.Operators {
		key := strings.ToLower(op.KeyID)
		if !keyIDPattern.MatchString(key) {
			writeError(w, errBadRequest, "operators[].key_id must be 64 hex characters")
			return
		}
		name := strings.TrimSpace(op.Name)
		if name == "" {
			writeError(w, errBadRequest, "operators[].name is required")
			return
		}
		ops = append(ops, operator{Name: truncate(name, 80), KeyID: key})
	}
	ttl := defaultCodeTTL
	if body.ExpiresIn != nil {
		ttl = time.Duration(*body.ExpiresIn * float64(time.Second))
		if ttl <= 0 || ttl > maxCodeTTL {
			writeError(w, errBadRequest, "expires_in must be 1..86400 seconds")
			return
		}
	}
	org := ""
	if body.Organization != nil {
		org = truncate(strings.TrimSpace(*body.Organization), 80)
	}
	c, expires := rl.st.createCode(ops, org, body.Capabilities, ttl)
	event("enroll operators=%d", len(ops))
	writeJSON(w, 201, map[string]any{
		"code": c, "display_code": c[:4] + "-" + c[4:], "expires_at": expires.Unix(),
		"server": rl.st.server, "invite": rl.st.inviteLink(c, expires, ops),
	})
}

func (rl *relay) preview(w http.ResponseWriter, r *http.Request) {
	if !rl.st.allow("enroll", rl.source(r), enrollRate) {
		writeError(w, errRateLimited, "")
		return
	}
	var body struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &body, true) {
		return
	}
	info, err := rl.st.preview(body.Code)
	if err != nil {
		writeError(w, err, "")
		return
	}
	writeJSON(w, 200, info)
}

func (rl *relay) redeem(w http.ResponseWriter, r *http.Request) {
	if !rl.st.allow("enroll", rl.source(r), enrollRate) {
		writeError(w, errRateLimited, "")
		return
	}
	var body struct {
		Code      string `json:"code"`
		PublicKey string `json:"device_public_key"`
		Name      string `json:"device_name"`
		Proof     string `json:"proof"`
	}
	if !readJSON(w, r, &body, true) {
		return
	}
	key, ok1 := unb64url(body.PublicKey)
	proof, ok2 := unb64url(body.Proof)
	if !ok1 || !ok2 || len(key) != ed25519.PublicKeySize || len(proof) != ed25519.SignatureSize {
		writeError(w, errBadRequest, "device_public_key (32 bytes), proof (64 bytes) and device_name are required")
		return
	}
	d, err := rl.st.redeem(body.Code, key, body.Name, proof)
	if err != nil {
		event("redeem status=%v", err)
		writeError(w, err, "")
		return
	}
	event("redeem status=200 device=%s", d.ID)
	writeJSON(w, 200, map[string]any{
		"device_id": d.ID, "organization": d.Organization, "operators": d.Operators,
		"public_url": rl.publicURL(d), "tunnel": 1,
	})
}

func (rl *relay) challenge(w http.ResponseWriter, r *http.Request) {
	if !rl.st.allow("auth", rl.source(r), authRate) {
		writeError(w, errRateLimited, "")
		return
	}
	var body struct {
		DeviceID string `json:"device_id"`
	}
	if !readJSON(w, r, &body, true) {
		return
	}
	nonce, err := rl.st.challenge(body.DeviceID)
	if err != nil {
		writeError(w, err, "")
		return
	}
	writeJSON(w, 200, map[string]any{"nonce": nonce, "expires_in": int(challengeTTL.Seconds())})
}

func (rl *relay) session(w http.ResponseWriter, r *http.Request) {
	if !rl.st.allow("auth", rl.source(r), authRate) {
		writeError(w, errRateLimited, "")
		return
	}
	var body struct {
		DeviceID string `json:"device_id"`
		Nonce    string `json:"nonce"`
		Sig      string `json:"sig"`
	}
	if !readJSON(w, r, &body, true) {
		return
	}
	sig, _ := unb64url(body.Sig)
	token, d, err := rl.st.openSession(body.DeviceID, body.Nonce, sig)
	if err != nil {
		event("session status=%v", err)
		writeError(w, err, "")
		return
	}
	event("session status=200 device=%s", d.ID)
	writeJSON(w, 200, map[string]any{
		"device_token": token, "expires_in": int(rl.st.deviceTTL.Seconds()),
		"public_url": rl.publicURL(d), "tunnel": 1,
	})
}

var unbindField = regexp.MustCompile(`(\w+)=([^,\s]+)`)

func (rl *relay) unbind(w http.ResponseWriter, r *http.Request, deviceID string) {
	if !deviceIDPattern.MatchString(deviceID) {
		writeJSON(w, 404, map[string]any{"error": "not_found"})
		return
	}
	scheme, rest, _ := strings.Cut(r.Header.Get("Authorization"), " ")
	fields := map[string]string{}
	if scheme == "LoopCtrl-Device" {
		for _, m := range unbindField.FindAllStringSubmatch(rest, -1) {
			fields[m[1]] = m[2]
		}
	}
	sig, _ := unb64url(fields["sig"])
	ts, err := strconv.ParseInt(fields["ts"], 10, 64)
	if err != nil {
		writeError(w, errBadSignature, "")
		return
	}
	if err := rl.st.unbind(deviceID, ts, sig); err != nil {
		writeError(w, err, "")
		return
	}
	event("unbind device=%s", deviceID)
	writeJSON(w, 200, map[string]any{"ok": true})
}

// MARK: tunnel

func (rl *relay) tunnel(w http.ResponseWriter, r *http.Request) {
	d := rl.st.deviceForToken(bearer(r))
	if d == nil {
		writeJSON(w, 401, map[string]any{"error": "unauthorized"})
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols:    []string{"loopctrl-tunnel-v1"},
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	t := newTunnel(d.ID, conn)
	hello, _ := json.Marshal(map[string]any{
		"type": "hello", "public_url": rl.publicURL(d), "max_frame": maxFrame, "window": initialWindow,
	})
	if err := t.write(websocket.MessageText, hello); err != nil {
		t.close("hello failed")
		return
	}
	if old := rl.st.attach(t); old != nil {
		old.close("replaced by a new tunnel")
	}
	event("tunnel open device=%s", d.ID)
	t.run(func() { rl.st.touch(d.ID) })
	rl.st.detach(t)
}

// MARK: forwarding

// hopHeaders never cross the tunnel; the phone's own X-LoopCtrl-Relay-*
// headers are set by the phone, so the relay may not send them either.
var hopHeaders = map[string]bool{
	"Connection": true, "Keep-Alive": true, "Proxy-Connection": true, "Proxy-Authenticate": true,
	"Proxy-Authorization": true, "Te": true, "Trailer": true, "Transfer-Encoding": true, "Upgrade": true,
	"Host": true, "Content-Length": true,
}

func (rl *relay) forward(w http.ResponseWriter, r *http.Request, slug, target string) {
	d, t := rl.st.deviceBySlug(slug)
	if d == nil {
		http.NotFound(w, r)
		return
	}
	if t == nil {
		offline(w)
		return
	}
	peer := rl.source(r)
	if r.Method == http.MethodPost && strings.HasPrefix(target, "/pair") &&
		!rl.st.allow("pair:"+d.ID, peer, pairRate) {
		writeError(w, errRateLimited, "")
		return
	}
	if r.ContentLength > maxProxiedBody {
		writeJSON(w, 413, map[string]any{"error": "body_too_large"})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxProxiedBody+1))
	if err != nil {
		return
	}
	if len(body) > maxProxiedBody {
		writeJSON(w, 413, map[string]any{"error": "body_too_large"})
		return
	}

	req := openRequest{Method: r.Method, Path: target, Peer: peer}
	for name, values := range r.Header {
		if hopHeaders[name] || strings.HasPrefix(name, "X-Loopctrl-Relay") {
			continue
		}
		for _, v := range values {
			req.Headers = append(req.Headers, [2]string{name, v})
		}
	}
	if len(body) > 0 || r.Method == http.MethodPost || r.Method == http.MethodPut {
		req.Headers = append(req.Headers, [2]string{"Content-Length", strconv.Itoa(len(body))})
	}

	s, err := t.open(req)
	if err != nil {
		if errors.Is(err, errTooMany) {
			writeJSON(w, 429, map[string]any{"error": "device_busy"})
		} else {
			offline(w)
		}
		return
	}
	done := make(chan struct{})
	defer func() {
		close(done)
		s.finish()
	}()
	go func() {
		select {
		case <-r.Context().Done():
			s.abort("client went away")
		case <-done:
		}
	}()
	if len(body) > 0 {
		if _, err := s.Write(body); err != nil {
			offline(w)
			return
		}
	}
	if err := s.closeWrite(); err != nil {
		offline(w)
		return
	}

	resp, err := http.ReadResponse(bufio.NewReaderSize(s, maxFrame), r)
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": "bad_device_response"})
		return
	}
	defer resp.Body.Close()
	h := w.Header()
	for name, values := range resp.Header {
		if hopHeaders[name] && name != "Content-Length" {
			continue
		}
		for _, v := range values {
			h.Add(name, v)
		}
	}
	h.Set("X-Robots-Tag", "noindex, nofollow")
	h.Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, maxFrame)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

func offline(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Retry-After", "5")
	w.WriteHeader(http.StatusServiceUnavailable)
	_, _ = io.WriteString(w, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">`+
		`<title>Phone offline</title><body style="font:16px system-ui;margin:3em auto;max-width:28em;padding:0 1em">`+
		`<h1 style="font-size:1.4em">The phone is not connected</h1>`+
		`<p>Open LoopCtrl on the phone and turn on the remote service, then reload this page.</p>`+
		`<p lang="zh">请在手机上打开 LoopCtrl 并开启远程服务，然后刷新本页。</p>`)
}

// MARK: helpers

func (rl *relay) requireOperator(w http.ResponseWriter, r *http.Request) bool {
	if rl.st.isOperator(bearer(r)) {
		return true
	}
	writeJSON(w, 401, map[string]any{"error": "unauthorized"})
	return false
}

// source is the client address, taken from X-Real-IP only when the direct
// peer is a trusted proxy.
func (rl *relay) source(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	for _, p := range rl.cfg.trustedHosts {
		if p.Contains(addr.Unmap()) {
			if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
				return real
			}
		}
	}
	return host
}

func bearer(r *http.Request) string {
	scheme, token, ok := strings.Cut(r.Header.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return ""
	}
	return strings.TrimSpace(token)
}

func readJSON(w http.ResponseWriter, r *http.Request, v any, required bool) bool {
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxJSONBody+1))
	if err != nil {
		return false
	}
	if len(raw) > maxJSONBody {
		writeJSON(w, 413, map[string]any{"error": "body_too_large"})
		return false
	}
	if len(raw) == 0 {
		if required {
			writeError(w, errBadRequest, "JSON body required")
			return false
		}
		return true
	}
	if err := json.Unmarshal(raw, v); err != nil {
		writeError(w, errBadRequest, "body must be a JSON object")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	raw, _ := json.Marshal(v)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(raw)
}

func writeError(w http.ResponseWriter, err error, message string) {
	code, ok := err.(relayError)
	if !ok {
		writeJSON(w, 500, map[string]any{"error": "internal"})
		return
	}
	status := errorStatus[code]
	if status == 0 {
		status = 400
	}
	if message == "" {
		message = errorMessage[code]
	}
	if message == "" {
		message = string(code)
	}
	writeJSON(w, status, map[string]any{"error": string(code), "message": message})
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func event(format string, args ...any) {
	if eventLog {
		log.Printf(format, args...)
	}
}
