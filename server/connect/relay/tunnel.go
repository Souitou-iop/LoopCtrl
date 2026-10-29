package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	pingInterval = 20 * time.Second
	// The phone's pong waits behind the video already queued on its uplink;
	// on a busy cellular link that can take longer than 10 s, and a tunnel
	// dropped for it cuts every viewer at once.
	pingTimeout     = 30 * time.Second
	writeTimeout    = 15 * time.Second
	maxStreams      = 64
	creditThreshold = 32 * 1024
)

var (
	errTunnelClosed = errors.New("tunnel closed")
	errStreamReset  = errors.New("stream reset by the device")
	errTooMany      = errors.New("too many open streams")
)

// openRequest is the head of one HTTP exchange, sent to the phone in OPEN.
type openRequest struct {
	Method  string      `json:"method"`
	Path    string      `json:"path"`
	Headers [][2]string `json:"headers"`
	Peer    string      `json:"peer"`
}

// tunnel is one phone's WebSocket. The relay opens streams on it, one per
// HTTP exchange; the phone answers with the raw HTTP response.
type tunnel struct {
	deviceID string
	conn     *websocket.Conn
	ctx      context.Context
	cancel   context.CancelFunc

	writeMu sync.Mutex

	mu      sync.Mutex
	streams map[uint32]*stream
	next    uint32
	closed  bool
}

func newTunnel(deviceID string, conn *websocket.Conn) *tunnel {
	ctx, cancel := context.WithCancel(context.Background())
	conn.SetReadLimit(maxFrame + 1024)
	return &tunnel{deviceID: deviceID, conn: conn, ctx: ctx, cancel: cancel, streams: map[uint32]*stream{}, next: 1}
}

func (t *tunnel) streamCount() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.streams)
}

func (t *tunnel) write(kind websocket.MessageType, b []byte) error {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(t.ctx, writeTimeout)
	defer cancel()
	return t.conn.Write(ctx, kind, b)
}

func (t *tunnel) send(kind byte, id uint32, payload []byte) error {
	return t.write(websocket.MessageBinary, encodeFrame(kind, id, payload))
}

// run reads until the phone goes away, keeping the connection alive with
// pings and the device's session with touch.
func (t *tunnel) run(touch func()) {
	defer t.close("tunnel ended")
	go func() {
		tick := time.NewTicker(pingInterval)
		defer tick.Stop()
		for {
			select {
			case <-t.ctx.Done():
				return
			case <-tick.C:
				ctx, cancel := context.WithTimeout(t.ctx, pingTimeout)
				err := t.conn.Ping(ctx)
				cancel()
				if err != nil {
					t.close("ping failed")
					return
				}
				touch()
			}
		}
	}()
	for {
		kind, data, err := t.conn.Read(t.ctx)
		if err != nil {
			return
		}
		if kind != websocket.MessageBinary {
			continue
		}
		typ, id, payload, err := decodeFrame(data)
		if err != nil {
			return
		}
		t.mu.Lock()
		s := t.streams[id]
		t.mu.Unlock()
		if s == nil {
			// Late traffic for a stream already gone: nothing to do.
			continue
		}
		switch typ {
		case frameData:
			if !s.deliver(payload) {
				s.abort("flow control violated")
			}
		case frameEnd:
			s.endInput()
		case frameReset:
			s.remoteReset()
		case frameWindow:
			if len(payload) == 4 {
				s.credit(binary.BigEndian.Uint32(payload))
			}
		}
	}
}

func (t *tunnel) close(reason string) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	t.closed = true
	streams := t.streams
	t.streams = map[uint32]*stream{}
	t.mu.Unlock()
	for _, s := range streams {
		s.fail(errTunnelClosed)
	}
	t.cancel()
	_ = t.conn.Close(websocket.StatusGoingAway, reason)
	if eventLog {
		log.Printf("tunnel closed device=%s reason=%q", t.deviceID, reason)
	}
}

// open starts one exchange.
func (t *tunnel) open(req openRequest) (*stream, error) {
	head, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil, errTunnelClosed
	}
	if len(t.streams) >= maxStreams {
		t.mu.Unlock()
		return nil, errTooMany
	}
	id := t.next
	t.next++
	s := &stream{t: t, id: id, sendCredit: initialWindow}
	s.cond = sync.NewCond(&s.mu)
	t.streams[id] = s
	t.mu.Unlock()
	if err := t.send(frameOpen, id, head); err != nil {
		s.fail(err)
		t.forget(id)
		return nil, err
	}
	return s, nil
}

func (t *tunnel) forget(id uint32) {
	t.mu.Lock()
	delete(t.streams, id)
	t.mu.Unlock()
}

// stream is one exchange as the relay sees it: an io.Writer for the request
// body, an io.Reader for the raw response.
type stream struct {
	t  *tunnel
	id uint32

	mu         sync.Mutex
	cond       *sync.Cond
	buf        []byte
	inEnded    bool
	err        error
	sendCredit int64
	unacked    int
	outEnded   bool
}

// deliver queues data from the phone; false if it sent past its window.
func (s *stream) deliver(p []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err != nil {
		return true
	}
	if len(s.buf)+len(p) > initialWindow {
		return false
	}
	s.buf = append(s.buf, p...)
	s.cond.Broadcast()
	return true
}

func (s *stream) endInput() {
	s.mu.Lock()
	s.inEnded = true
	s.cond.Broadcast()
	s.mu.Unlock()
}

func (s *stream) credit(n uint32) {
	s.mu.Lock()
	s.sendCredit += int64(n)
	s.cond.Broadcast()
	s.mu.Unlock()
}

func (s *stream) remoteReset() {
	s.fail(errStreamReset)
	s.t.forget(s.id)
}

func (s *stream) fail(err error) {
	s.mu.Lock()
	if s.err == nil {
		s.err = err
	}
	s.cond.Broadcast()
	s.mu.Unlock()
}

// abort gives up on the exchange (the browser left, or the phone broke the
// protocol) and tells the phone.
func (s *stream) abort(reason string) {
	s.mu.Lock()
	already := s.err != nil
	if !already {
		s.err = errors.New(reason)
	}
	s.cond.Broadcast()
	s.mu.Unlock()
	s.t.forget(s.id)
	if !already {
		_ = s.t.send(frameReset, s.id, []byte(reason))
	}
}

// Read hands out the phone's response bytes and returns their credit.
func (s *stream) Read(p []byte) (int, error) {
	s.mu.Lock()
	for len(s.buf) == 0 && !s.inEnded && s.err == nil {
		s.cond.Wait()
	}
	if len(s.buf) == 0 {
		err := s.err
		s.mu.Unlock()
		if err != nil {
			return 0, err
		}
		return 0, io.EOF
	}
	n := copy(p, s.buf)
	s.buf = s.buf[n:]
	s.unacked += n
	var grant int
	if s.unacked >= creditThreshold {
		grant, s.unacked = s.unacked, 0
	}
	s.mu.Unlock()
	if grant > 0 {
		_ = s.t.send(frameWindow, s.id, windowPayload(uint32(grant)))
	}
	return n, nil
}

// Write sends request body bytes, waiting for credit.
func (s *stream) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		s.mu.Lock()
		for s.sendCredit <= 0 && s.err == nil {
			s.cond.Wait()
		}
		if s.err != nil {
			err := s.err
			s.mu.Unlock()
			return written, err
		}
		n := len(p)
		if n > maxFrame {
			n = maxFrame
		}
		if int64(n) > s.sendCredit {
			n = int(s.sendCredit)
		}
		s.sendCredit -= int64(n)
		s.mu.Unlock()
		if err := s.t.send(frameData, s.id, p[:n]); err != nil {
			s.fail(err)
			return written, err
		}
		written += n
		p = p[n:]
	}
	return written, nil
}

// closeWrite ends the request body.
func (s *stream) closeWrite() error {
	s.mu.Lock()
	if s.outEnded || s.err != nil {
		s.mu.Unlock()
		return s.err
	}
	s.outEnded = true
	s.mu.Unlock()
	return s.t.send(frameEnd, s.id, nil)
}

// finish releases the stream once the exchange is over, telling the phone
// to stop if it has not finished on its own.
func (s *stream) finish() {
	s.mu.Lock()
	done := s.inEnded && len(s.buf) == 0
	s.mu.Unlock()
	if done {
		s.t.forget(s.id)
		return
	}
	s.abort("closed by the relay")
}
