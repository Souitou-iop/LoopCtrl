package main

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	apiVersion       = 1
	defaultCodeTTL   = 10 * time.Minute
	maxCodeTTL       = 24 * time.Hour
	defaultDeviceTTL = time.Hour
	challengeTTL     = 60 * time.Second
	unbindSkew       = 5 * time.Minute

	codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	codeLength   = 8
	// slugAlphabet is DNS-label safe: a slug is one label of the device host.
	slugAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"
	slugLength   = 16
)

var (
	keyIDPattern    = regexp.MustCompile(`^[0-9a-f]{64}$`)
	deviceIDPattern = regexp.MustCompile(`^dev_[0-9a-f]{16}$`)
	slugPattern     = regexp.MustCompile(`^[a-z2-9]{16}$`)

	knownCapabilities = []string{"view_screen", "control", "launch_apps", "read_text"}
)

// relayError is an API error code; httpStatus and message map it for the wire.
type relayError string

func (e relayError) Error() string { return string(e) }

const (
	errInvalidCode   relayError = "invalid_code"
	errExpiredCode   relayError = "expired_code"
	errBadProof      relayError = "bad_proof"
	errBadRequest    relayError = "bad_request"
	errUnknownDevice relayError = "unknown_device"
	errBadChallenge  relayError = "bad_challenge"
	errBadSignature  relayError = "bad_signature"
	errTSSkew        relayError = "ts_skew"
	errRateLimited   relayError = "rate_limited"
)

var errorStatus = map[relayError]int{
	errInvalidCode: 404, errExpiredCode: 410, errBadProof: 400, errBadRequest: 400,
	errUnknownDevice: 404, errBadChallenge: 401, errBadSignature: 401, errTSSkew: 401,
	errRateLimited: 429,
}

var errorMessage = map[relayError]string{
	errInvalidCode:   "No such connection code.",
	errExpiredCode:   "This connection code has expired or was already used.",
	errBadProof:      "The enrollment proof does not verify for this server.",
	errUnknownDevice: "This device is not enrolled here.",
	errBadChallenge:  "Unknown or expired challenge.",
	errBadSignature:  "Signature does not verify.",
	errTSSkew:        "Timestamp too far from server time.",
	errRateLimited:   "Too many requests; slow down.",
}

type operator struct {
	Name  string `json:"name"`
	KeyID string `json:"key_id"`
}

type code struct {
	organization string
	operators    []operator
	capabilities []string
	expiresAt    time.Time
	used         bool
}

// device is an enrolled phone. Persisted; holds public material only.
type device struct {
	ID           string     `json:"device_id"`
	PublicKey    string     `json:"public_key"`
	Slug         string     `json:"slug"`
	Name         string     `json:"name"`
	Organization string     `json:"organization"`
	Operators    []operator `json:"operators"`
	EnrolledAt   int64      `json:"enrolled_at"`

	key ed25519.PublicKey
}

type challenge struct {
	nonce     string
	expiresAt time.Time
}

// session is a device's current sign-in: the bearer token its tunnel uses.
type session struct {
	deviceID  string
	tokenHash [32]byte
	expiresAt time.Time
}

type stateFile struct {
	Version int       `json:"version"`
	Devices []*device `json:"devices"`
}

// state holds everything the relay knows. Device records survive restarts;
// codes, challenges, tokens and tunnels live in memory only.
type state struct {
	server        string // normalised public name signatures are bound to
	operatorToken string
	organization  string
	file          string
	deviceTTL     time.Duration
	now           func() time.Time

	mu         sync.Mutex
	codes      map[string]*code
	devices    map[string]*device
	bySlug     map[string]*device
	challenges map[string]challenge
	sessions   map[string]*session // by device id
	byToken    map[[32]byte]*session
	tunnels    map[string]*tunnel // by device id
	rate       map[string][]time.Time
}

func newState(server, operatorToken, organization, file string) (*state, error) {
	s := &state{
		server:        normalizeServer(server),
		operatorToken: operatorToken,
		organization:  organization,
		file:          file,
		deviceTTL:     defaultDeviceTTL,
		now:           time.Now,
		codes:         map[string]*code{},
		devices:       map[string]*device{},
		bySlug:        map[string]*device{},
		challenges:    map[string]challenge{},
		sessions:      map[string]*session{},
		byToken:       map[[32]byte]*session{},
		tunnels:       map[string]*tunnel{},
		rate:          map[string][]time.Time{},
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// MARK: persistence

func (s *state) load() error {
	if s.file == "" {
		return nil
	}
	raw, err := os.ReadFile(s.file)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var f stateFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return fmt.Errorf("%s: %w", s.file, err)
	}
	minted := false
	for _, d := range f.Devices {
		key, ok := unb64url(d.PublicKey)
		if !ok || len(key) != ed25519.PublicKeySize || !deviceIDPattern.MatchString(d.ID) {
			continue
		}
		d.key = key
		if len(d.Name) > 120 {
			d.Name = d.Name[:120]
		}
		// Records from the poll relay have no slug: give them one, so a phone
		// enrolled there gets a public address without enrolling again.
		if !slugPattern.MatchString(d.Slug) || s.bySlug[d.Slug] != nil {
			d.Slug = s.newSlugLocked()
			minted = true
		}
		s.devices[d.ID] = d
		s.bySlug[d.Slug] = d
	}
	if minted {
		return s.saveLocked()
	}
	return nil
}

func (s *state) saveLocked() error {
	if s.file == "" {
		return nil
	}
	list := make([]*device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].EnrolledAt < list[j].EnrolledAt })
	raw, err := json.MarshalIndent(stateFile{Version: 1, Devices: list}, "", " ")
	if err != nil {
		return err
	}
	tmp := s.file + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.file)
}

// MARK: limits and operators

// allow is a sliding one-minute rate limit per (bucket, key).
func (s *state) allow(bucket, key string, perMinute int) bool {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	id := bucket + "\x00" + key
	hits := s.rate[id][:0]
	for _, t := range s.rate[id] {
		if t.After(now.Add(-time.Minute)) {
			hits = append(hits, t)
		}
	}
	if len(hits) >= perMinute {
		s.rate[id] = hits
		return false
	}
	s.rate[id] = append(hits, now)
	if len(s.rate) > 10_000 {
		for k, v := range s.rate {
			if len(v) == 0 || v[len(v)-1].Before(now.Add(-time.Minute)) {
				delete(s.rate, k)
			}
		}
	}
	return true
}

func (s *state) isOperator(token string) bool {
	return token != "" && hmac.Equal([]byte(token), []byte(s.operatorToken))
}

// MARK: enrollment

func (s *state) createCode(ops []operator, organization string, capabilities []string, ttl time.Duration) (string, time.Time) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropExpiredLocked(now)
	var c string
	for {
		c = randomString(codeAlphabet, codeLength)
		if s.codes[c] == nil {
			break
		}
	}
	if organization == "" {
		organization = s.organization
	}
	if capabilities == nil {
		capabilities = knownCapabilities
	}
	if ops == nil {
		ops = []operator{}
	}
	s.codes[c] = &code{organization: organization, operators: ops, capabilities: capabilities, expiresAt: now.Add(ttl)}
	return c, now.Add(ttl)
}

func (s *state) inviteLink(c string, expiresAt time.Time, ops []operator) string {
	parts := []string{fmt.Sprintf("v=%d", apiVersion), "server=" + escapeServer(s.server), "code=" + c}
	if len(ops) > 0 {
		ids := make([]string, len(ops))
		for i, op := range ops {
			ids[i] = op.KeyID
		}
		parts = append(parts, "op="+strings.Join(ids, ","))
	}
	parts = append(parts, fmt.Sprintf("exp=%d", expiresAt.Unix()))
	return "loopctrl://connect?" + strings.Join(parts, "&")
}

func (s *state) codeLocked(c string, now time.Time) (*code, error) {
	entry := s.codes[c]
	if entry == nil {
		return nil, errInvalidCode
	}
	if entry.used || !entry.expiresAt.After(now) {
		return nil, errExpiredCode
	}
	return entry, nil
}

func (s *state) preview(raw string) (map[string]any, error) {
	c, ok := normalizeCode(raw)
	if !ok {
		return nil, errInvalidCode
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, err := s.codeLocked(c, s.now())
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"organization":    entry.organization,
		"operators":       entry.operators,
		"capabilities":    entry.capabilities,
		"code_expires_at": entry.expiresAt.Unix(),
	}, nil
}

func (s *state) redeem(raw string, key ed25519.PublicKey, name string, proof []byte) (*device, error) {
	c, ok := normalizeCode(raw)
	if !ok {
		return nil, errInvalidCode
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, err := s.codeLocked(c, now)
	if err != nil {
		return nil, err
	}
	// Checked before the code is spent, so a bad proof can't burn it.
	if !ed25519.Verify(key, enrollMessage(c, s.server), proof) {
		return nil, errBadProof
	}
	entry.used = true
	var id string
	for {
		id = "dev_" + randomHex(8)
		if s.devices[id] == nil {
			break
		}
	}
	name = strings.TrimSpace(name)
	if len(name) > 120 {
		name = name[:120]
	}
	if name == "" {
		name = "LoopCtrl device"
	}
	d := &device{
		ID: id, PublicKey: b64url(key), Slug: s.newSlugLocked(), Name: name,
		Organization: entry.organization, Operators: entry.operators, EnrolledAt: now.Unix(), key: key,
	}
	s.devices[id] = d
	s.bySlug[d.Slug] = d
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	return d, nil
}

func (s *state) newSlugLocked() string {
	for {
		slug := randomString(slugAlphabet, slugLength)
		if s.bySlug[slug] == nil {
			return slug
		}
	}
}

// MARK: device sign-in

func (s *state) challenge(deviceID string) (string, error) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.devices[deviceID] == nil {
		return "", errUnknownDevice
	}
	nonce := b64url(randomBytes(32))
	s.challenges[deviceID] = challenge{nonce: nonce, expiresAt: now.Add(challengeTTL)}
	return nonce, nil
}

func (s *state) openSession(deviceID, nonce string, sig []byte) (string, *device, error) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.devices[deviceID]
	if d == nil {
		return "", nil, errUnknownDevice
	}
	pending, ok := s.challenges[deviceID]
	delete(s.challenges, deviceID)
	if !ok || !pending.expiresAt.After(now) || !hmac.Equal([]byte(pending.nonce), []byte(nonce)) {
		return "", nil, errBadChallenge
	}
	if !ed25519.Verify(d.key, channelMessage(nonce, s.server), sig) {
		return "", nil, errBadSignature
	}
	token := b64url(randomBytes(32))
	hash := hashToken(token)
	if old := s.sessions[deviceID]; old != nil {
		delete(s.byToken, old.tokenHash)
	}
	sess := &session{deviceID: deviceID, tokenHash: hash, expiresAt: now.Add(s.deviceTTL)}
	s.sessions[deviceID] = sess
	s.byToken[hash] = sess
	return token, d, nil
}

// deviceForToken resolves a bearer token and extends its session.
func (s *state) deviceForToken(token string) *device {
	if token == "" {
		return nil
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	sess := s.byToken[hashToken(token)]
	if sess == nil {
		return nil
	}
	if !sess.expiresAt.After(now) {
		s.dropSessionLocked(sess)
		return nil
	}
	sess.expiresAt = now.Add(s.deviceTTL)
	return s.devices[sess.deviceID]
}

// touch keeps a device's session alive while its tunnel is up.
func (s *state) touch(deviceID string) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess := s.sessions[deviceID]; sess != nil {
		sess.expiresAt = now.Add(s.deviceTTL)
	}
}

func (s *state) unbind(deviceID string, ts int64, sig []byte) error {
	now := s.now()
	s.mu.Lock()
	d := s.devices[deviceID]
	if d == nil {
		s.mu.Unlock()
		return errUnknownDevice
	}
	if skew := now.Sub(time.Unix(ts, 0)); skew > unbindSkew || skew < -unbindSkew {
		s.mu.Unlock()
		return errTSSkew
	}
	if !ed25519.Verify(d.key, unbindMessage(deviceID, ts, s.server), sig) {
		s.mu.Unlock()
		return errBadSignature
	}
	t := s.tunnels[deviceID]
	delete(s.tunnels, deviceID)
	delete(s.devices, deviceID)
	delete(s.bySlug, d.Slug)
	delete(s.challenges, deviceID)
	if sess := s.sessions[deviceID]; sess != nil {
		s.dropSessionLocked(sess)
	}
	err := s.saveLocked()
	s.mu.Unlock()
	if t != nil {
		t.close("device unbound")
	}
	return err
}

func (s *state) dropSessionLocked(sess *session) {
	delete(s.byToken, sess.tokenHash)
	if s.sessions[sess.deviceID] == sess {
		delete(s.sessions, sess.deviceID)
	}
}

func (s *state) dropExpiredLocked(now time.Time) {
	for c, entry := range s.codes {
		if !entry.expiresAt.After(now) {
			delete(s.codes, c)
		}
	}
	for id, ch := range s.challenges {
		if !ch.expiresAt.After(now) {
			delete(s.challenges, id)
		}
	}
	for _, sess := range s.sessions {
		if !sess.expiresAt.After(now) && s.tunnels[sess.deviceID] == nil {
			s.dropSessionLocked(sess)
		}
	}
}

// MARK: tunnels

// attach makes t the device's tunnel and returns the one it replaces.
func (s *state) attach(t *tunnel) *tunnel {
	s.mu.Lock()
	defer s.mu.Unlock()
	old := s.tunnels[t.deviceID]
	s.tunnels[t.deviceID] = t
	return old
}

func (s *state) detach(t *tunnel) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tunnels[t.deviceID] == t {
		delete(s.tunnels, t.deviceID)
	}
}

func (s *state) deviceBySlug(slug string) (*device, *tunnel) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.bySlug[slug]
	if d == nil {
		return nil, nil
	}
	return d, s.tunnels[d.ID]
}

func (s *state) listDevices(publicURL func(*device) string) []map[string]any {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropExpiredLocked(now)
	list := make([]*device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].EnrolledAt < list[j].EnrolledAt })
	out := make([]map[string]any, 0, len(list))
	for _, d := range list {
		t := s.tunnels[d.ID]
		row := map[string]any{
			"device_id": d.ID, "name": d.Name, "organization": d.Organization,
			"operators": d.Operators, "public_url": publicURL(d), "online": t != nil, "streams": 0,
		}
		if t != nil {
			row["streams"] = t.streamCount()
		}
		out = append(out, row)
	}
	return out
}

// MARK: helpers

func normalizeCode(raw string) (string, bool) {
	var b strings.Builder
	for _, ch := range strings.ToUpper(raw) {
		switch ch {
		case '-', ' ', '‐', '‑', '–', '—':
			continue
		case 'O':
			ch = '0'
		case 'I', 'L':
			ch = '1'
		}
		if !strings.ContainsRune(codeAlphabet, ch) {
			return "", false
		}
		b.WriteRune(ch)
	}
	if b.Len() != codeLength {
		return "", false
	}
	return b.String(), true
}

// normalizeServer gives `host[:port][/path]` as the phone names this relay in
// signatures: no scheme, lower-case host, no trailing slash.
func normalizeServer(raw string) string {
	s := strings.TrimSpace(raw)
	for _, p := range []string{"https://", "http://"} {
		if strings.HasPrefix(strings.ToLower(s), p) {
			s = s[len(p):]
		}
	}
	s = strings.TrimRight(s, "/")
	host, path, found := strings.Cut(s, "/")
	if found {
		return strings.ToLower(host) + "/" + path
	}
	return strings.ToLower(host)
}

func escapeServer(server string) string {
	return strings.ReplaceAll(url.PathEscape(server), "%2F", "/")
}

func enrollMessage(c, server string) []byte {
	return []byte("loopctrl-enroll-v1\n" + c + "\n" + server)
}

func channelMessage(nonce, server string) []byte {
	return []byte("loopctrl-channel-v1\n" + nonce + "\n" + server)
}

func unbindMessage(deviceID string, ts int64, server string) []byte {
	return []byte(fmt.Sprintf("loopctrl-unbind-v1\n%s\n%d\n%s", deviceID, ts, server))
}

func hashToken(token string) [32]byte {
	m := hmac.New(sha256.New, []byte("loopctrl-relay-token-v1"))
	m.Write([]byte(token))
	var out [32]byte
	copy(out[:], m.Sum(nil))
	return out
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func unb64url(s string) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
	return b, err == nil
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func randomHex(n int) string { return hex.EncodeToString(randomBytes(n)) }

func randomString(alphabet string, n int) string {
	max := big.NewInt(int64(len(alphabet)))
	b := make([]byte, n)
	for i := range b {
		v, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic(err)
		}
		b[i] = alphabet[v.Int64()]
	}
	return string(b)
}
