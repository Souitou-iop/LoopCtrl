package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const testToken = "test-operator-token-0123456789"

type harness struct {
	t      *testing.T
	st     *state
	srv    *httptest.Server
	server string // the relay's public name
}

func newHarness(t *testing.T, cfg config) *harness {
	t.Helper()
	srv := httptest.NewUnstartedServer(nil)
	server := srv.Listener.Addr().String()
	st, err := newState(server, testToken, "Test Org", filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.publicScheme == "" {
		cfg.publicScheme = "http"
	}
	srv.Config.Handler = &relay{st: st, cfg: cfg}
	srv.Start()
	t.Cleanup(srv.Close)
	return &harness{t: t, st: st, srv: srv, server: server}
}

func (h *harness) call(method, path string, body any, header map[string]string) (int, map[string]any) {
	h.t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, h.srv.URL+path, rd)
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// enroll runs the whole phone side of enrollment and sign-in and returns the
// device id, the bearer token and the public address.
func (h *harness) enroll(key ed25519.PrivateKey, operatorKey string) (string, string, string) {
	h.t.Helper()
	status, minted := h.call("POST", "/v1/admin/enrollments",
		map[string]any{"operators": []map[string]string{{"name": "Alex", "key_id": operatorKey}}},
		map[string]string{"Authorization": "Bearer " + testToken})
	if status != 201 {
		h.t.Fatalf("enrollments: %d %v", status, minted)
	}
	code := minted["code"].(string)
	if !strings.Contains(minted["invite"].(string), "op="+operatorKey) {
		h.t.Fatalf("invite lacks op: %v", minted["invite"])
	}
	if status, info := h.call("POST", "/v1/enroll/preview", map[string]any{"code": minted["display_code"]}, nil); status != 200 ||
		info["organization"] != "Test Org" {
		h.t.Fatalf("preview: %d %v", status, info)
	}
	pub := key.Public().(ed25519.PublicKey)
	proof := ed25519.Sign(key, enrollMessage(code, h.server))
	status, red := h.call("POST", "/v1/enroll/redeem", map[string]any{
		"code": code, "device_public_key": b64url(pub), "device_name": "iPhone", "proof": b64url(proof),
	}, nil)
	if status != 200 {
		h.t.Fatalf("redeem: %d %v", status, red)
	}
	if status, again := h.call("POST", "/v1/enroll/redeem", map[string]any{
		"code": code, "device_public_key": b64url(pub), "device_name": "iPhone", "proof": b64url(proof),
	}, nil); status != 410 {
		h.t.Fatalf("second redeem: %d %v", status, again)
	}
	id := red["device_id"].(string)
	_, ch := h.call("POST", "/v1/device/challenge", map[string]any{"device_id": id}, nil)
	nonce := ch["nonce"].(string)
	sig := ed25519.Sign(key, channelMessage(nonce, h.server))
	status, sess := h.call("POST", "/v1/device/session", map[string]any{"device_id": id, "nonce": nonce, "sig": b64url(sig)}, nil)
	if status != 200 {
		h.t.Fatalf("session: %d %v", status, sess)
	}
	if status, _ := h.call("POST", "/v1/device/session", map[string]any{"device_id": id, "nonce": nonce, "sig": b64url(sig)}, nil); status != 401 {
		h.t.Fatalf("replayed nonce accepted: %d", status)
	}
	return id, sess["device_token"].(string), sess["public_url"].(string)
}

// fakePhone answers tunnel streams the way LoopCtrl's tunnel client does,
// with a handler standing in for the phone's HTTP server.
type fakePhone struct {
	t       *testing.T
	conn    *websocket.Conn
	hello   map[string]any
	handler func(req openRequest, body []byte, w *phoneStream)

	writeMu sync.Mutex
	mu      sync.Mutex
	streams map[uint32]*phoneStream
	resets  atomic.Int32
}

type phoneStream struct {
	p       *fakePhone
	id      uint32
	req     openRequest
	body    bytes.Buffer
	mu      sync.Mutex
	cond    *sync.Cond
	credit  int64
	reset   bool
	maxSeen int64 // most bytes in flight at once
	sent    int64
	acked   int64
}

func dialPhone(t *testing.T, h *harness, token string, handler func(openRequest, []byte, *phoneStream)) *fakePhone {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, strings.Replace(h.srv.URL, "http", "ws", 1)+"/v1/device/tunnel", &websocket.DialOptions{
		HTTPHeader:   http.Header{"Authorization": {"Bearer " + token}},
		Subprotocols: []string{"loopctrl-tunnel-v1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	conn.SetReadLimit(1 << 20)
	kind, raw, err := conn.Read(ctx)
	if err != nil || kind != websocket.MessageText {
		t.Fatalf("hello: %v %v", kind, err)
	}
	p := &fakePhone{t: t, conn: conn, handler: handler, streams: map[uint32]*phoneStream{}}
	_ = json.Unmarshal(raw, &p.hello)
	go p.run()
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	return p
}

func (p *fakePhone) send(kind byte, id uint32, payload []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return p.conn.Write(context.Background(), websocket.MessageBinary, encodeFrame(kind, id, payload))
}

func (p *fakePhone) run() {
	for {
		_, raw, err := p.conn.Read(context.Background())
		if err != nil {
			p.mu.Lock()
			for _, s := range p.streams {
				s.mu.Lock()
				s.reset = true
				s.cond.Broadcast()
				s.mu.Unlock()
			}
			p.mu.Unlock()
			return
		}
		kind, id, payload, _ := decodeFrame(raw)
		p.mu.Lock()
		s := p.streams[id]
		p.mu.Unlock()
		switch kind {
		case frameOpen:
			s = &phoneStream{p: p, id: id, credit: initialWindow}
			s.cond = sync.NewCond(&s.mu)
			_ = json.Unmarshal(payload, &s.req)
			p.mu.Lock()
			p.streams[id] = s
			p.mu.Unlock()
		case frameData:
			s.body.Write(payload)
			_ = p.send(frameWindow, id, windowPayload(uint32(len(payload))))
		case frameEnd:
			go p.handler(s.req, s.body.Bytes(), s)
		case frameWindow:
			s.mu.Lock()
			n := int64(binary.BigEndian.Uint32(payload))
			s.credit += n
			s.acked += n
			s.cond.Broadcast()
			s.mu.Unlock()
		case frameReset:
			p.resets.Add(1)
			if s != nil {
				s.mu.Lock()
				s.reset = true
				s.cond.Broadcast()
				s.mu.Unlock()
			}
		}
	}
}

// Write sends response bytes within the window, like the real client.
func (s *phoneStream) Write(b []byte) error {
	for len(b) > 0 {
		s.mu.Lock()
		for s.credit <= 0 && !s.reset {
			s.cond.Wait()
		}
		if s.reset {
			s.mu.Unlock()
			return io.ErrClosedPipe
		}
		n := min(len(b), maxFrame, int(s.credit))
		s.credit -= int64(n)
		s.sent += int64(n)
		if inFlight := s.sent - s.acked; inFlight > s.maxSeen {
			s.maxSeen = inFlight
		}
		s.mu.Unlock()
		if err := s.p.send(frameData, s.id, b[:n]); err != nil {
			return err
		}
		b = b[n:]
	}
	return nil
}

func (s *phoneStream) End() { _ = s.p.send(frameEnd, s.id, nil) }

func echoHandler(req openRequest, body []byte, w *phoneStream) {
	headers := map[string]string{}
	for _, kv := range req.Headers {
		headers[kv[0]] = kv[1]
	}
	reply, _ := json.Marshal(map[string]any{
		"method": req.Method, "path": req.Path, "body": string(body), "peer": req.Peer, "headers": headers,
	})
	_ = w.Write([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(reply))))
	_ = w.Write(reply)
	w.End()
}

func operatorKeyID() string {
	sum := sha256.Sum256([]byte("operator"))
	return hex.EncodeToString(sum[:])
}

func TestEnrollTunnelAndForward(t *testing.T) {
	h := newHarness(t, config{pathRouting: true})
	_, key, _ := ed25519.GenerateKey(nil)
	id, token, public := h.enroll(key, operatorKeyID())
	if !strings.HasPrefix(public, "http://"+h.server+"/d/") || !strings.HasSuffix(public, "/") {
		t.Fatalf("public url %q", public)
	}

	// Offline until the phone connects.
	resp, err := http.Get(public + "remote")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 503 {
		t.Fatalf("offline: %d", resp.StatusCode)
	}

	phone := dialPhone(t, h, token, echoHandler)
	if phone.hello["public_url"] != public {
		t.Fatalf("hello %v", phone.hello)
	}

	req, _ := http.NewRequest("POST", public+"rpc?x=1", strings.NewReader(`{"v":1}`))
	req.Header.Set("X-LoopCtrl-Relay-Connection", "forged")
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&got)
	resp.Body.Close()
	if resp.StatusCode != 200 || got["path"] != "/rpc?x=1" || got["body"] != `{"v":1}` || got["method"] != "POST" {
		t.Fatalf("forwarded %d %v", resp.StatusCode, got)
	}
	headers := got["headers"].(map[string]any)
	if headers["Content-Type"] != "application/json" || headers["Content-Length"] != "7" {
		t.Fatalf("headers %v", headers)
	}
	for k := range headers {
		if strings.HasPrefix(strings.ToLower(k), "x-loopctrl-relay") {
			t.Fatalf("relay forwarded %s", k)
		}
	}
	if got["peer"] != "127.0.0.1" {
		t.Fatalf("peer %v", got["peer"])
	}

	// The device list sees the tunnel.
	_, list := h.call("GET", "/v1/admin/devices", nil, map[string]string{"Authorization": "Bearer " + testToken})
	row := list["devices"].([]any)[0].(map[string]any)
	if row["device_id"] != id || row["online"] != true {
		t.Fatalf("devices %v", list)
	}

	// A bare /d/<slug> sends the browser to the control page.
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, _ = client.Get(strings.TrimSuffix(public, "/"))
	resp.Body.Close()
	if resp.StatusCode != 302 || !strings.HasSuffix(resp.Header.Get("Location"), "/remote") {
		t.Fatalf("redirect %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
}

func TestSubdomainRouting(t *testing.T) {
	h := newHarness(t, config{deviceDomain: "r.test"})
	_, key, _ := ed25519.GenerateKey(nil)
	_, token, public := h.enroll(key, operatorKeyID())
	if !strings.HasPrefix(public, "http://") || !strings.HasSuffix(public, ".r.test/") {
		t.Fatalf("public url %q", public)
	}
	host := strings.TrimSuffix(strings.TrimPrefix(public, "http://"), "/")
	dialPhone(t, h, token, echoHandler)

	req, _ := http.NewRequest("GET", h.srv.URL+"/skill?a=b", nil)
	req.Host = host
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&got)
	resp.Body.Close()
	if got["path"] != "/skill?a=b" || resp.Header.Get("X-Robots-Tag") == "" {
		t.Fatalf("got %v %v", got, resp.Header)
	}
	// Path routing is off when phones have their own hosts.
	resp, _ = http.Get(h.srv.URL + "/d/" + strings.Split(host, ".")[0] + "/skill")
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("path routing answered %d", resp.StatusCode)
	}
}

// A response larger than the window arrives whole, and the phone never has
// more than a window in flight: the browser's pace reaches the phone.
func TestStreamingFlowControl(t *testing.T) {
	h := newHarness(t, config{pathRouting: true})
	_, key, _ := ed25519.GenerateKey(nil)
	_, token, public := h.enroll(key, operatorKeyID())
	const size = 3 << 20
	var stream *phoneStream
	var once sync.Once
	ready := make(chan struct{})
	dialPhone(t, h, token, func(req openRequest, body []byte, w *phoneStream) {
		once.Do(func() { stream = w; close(ready) })
		_ = w.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"))
		chunk := bytes.Repeat([]byte{0xab}, 10_000)
		for sent := 0; sent < size; sent += len(chunk) {
			if err := w.Write(chunk); err != nil {
				return
			}
		}
		w.End()
	})
	resp, err := http.Get(public + "stream")
	if err != nil {
		t.Fatal(err)
	}
	<-ready
	// Read slowly at first so the window has to fill.
	time.Sleep(200 * time.Millisecond)
	n, err := io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if err != nil || n < size {
		t.Fatalf("read %d bytes, %v", n, err)
	}
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if stream.maxSeen > initialWindow {
		t.Fatalf("phone had %d bytes in flight, window is %d", stream.maxSeen, initialWindow)
	}
}

// When the browser leaves, the phone is told to stop.
func TestClientGoneResetsStream(t *testing.T) {
	h := newHarness(t, config{pathRouting: true})
	_, key, _ := ed25519.GenerateKey(nil)
	_, token, public := h.enroll(key, operatorKeyID())
	stopped := make(chan struct{})
	phone := dialPhone(t, h, token, func(req openRequest, body []byte, w *phoneStream) {
		_ = w.Write([]byte("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"))
		for {
			if err := w.Write(make([]byte, 4096)); err != nil {
				close(stopped)
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, "GET", public+"stream", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.ReadFull(resp.Body, make([]byte, 10_000))
	cancel()
	resp.Body.Close()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("phone never saw a reset")
	}
	if phone.resets.Load() == 0 {
		t.Fatal("no RESET frame")
	}
}

func TestPairRateLimit(t *testing.T) {
	h := newHarness(t, config{pathRouting: true})
	_, key, _ := ed25519.GenerateKey(nil)
	_, token, public := h.enroll(key, operatorKeyID())
	dialPhone(t, h, token, echoHandler)
	limited := false
	for i := 0; i < pairRate+2; i++ {
		resp, err := http.Post(public+"pair", "application/json", strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == 429 {
			limited = true
		}
	}
	if !limited {
		t.Fatal("pairing was never rate limited")
	}
}

func TestReplacedTunnelAndUnbind(t *testing.T) {
	h := newHarness(t, config{pathRouting: true})
	_, key, _ := ed25519.GenerateKey(nil)
	id, token, public := h.enroll(key, operatorKeyID())
	first := dialPhone(t, h, token, echoHandler)
	dialPhone(t, h, token, echoHandler)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, _, err := first.conn.Read(ctx); err == nil {
		t.Fatal("the replaced tunnel stayed open")
	}
	ts := time.Now().Unix()
	sig := ed25519.Sign(key, unbindMessage(id, ts, h.server))
	status, _ := h.call("DELETE", "/v1/devices/"+id, nil, map[string]string{
		"Authorization": fmt.Sprintf("LoopCtrl-Device sig=%s, ts=%d", b64url(sig), ts),
	})
	if status != 200 {
		t.Fatalf("unbind %d", status)
	}
	resp, _ := http.Get(public + "remote")
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("unbound phone answered %d", resp.StatusCode)
	}
}

// Records written by the poll relay load, and get a public address.
func TestLegacyStateGetsSlugs(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "state.json")
	_, key, _ := ed25519.GenerateKey(nil)
	legacy := fmt.Sprintf(`{"version":1,"devices":[{"device_id":"dev_0123456789abcdef","public_key":"%s","name":"Old","organization":"O","operators":[],"enrolled_at":1}]}`,
		b64url(key.Public().(ed25519.PublicKey)))
	if err := os.WriteFile(file, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := newState("relay.test", testToken, "Org", file)
	if err != nil {
		t.Fatal(err)
	}
	d := st.devices["dev_0123456789abcdef"]
	if d == nil || !slugPattern.MatchString(d.Slug) {
		t.Fatalf("device %+v", d)
	}
	again, _ := newState("relay.test", testToken, "Org", file)
	if again.devices[d.ID].Slug != d.Slug {
		t.Fatal("slug not persisted")
	}
}

func TestNormalize(t *testing.T) {
	if got, ok := normalizeCode("7k3m-9qx2"); !ok || got != "7K3M9QX2" {
		t.Fatal(got)
	}
	if got, _ := normalizeCode("oil1-0000"); got != "0111"+"0000" {
		t.Fatal(got)
	}
	if got := normalizeServer("HTTPS://Example.COM/LoopCtrl-Relay/"); got != "example.com/LoopCtrl-Relay" {
		t.Fatal(got)
	}
}
