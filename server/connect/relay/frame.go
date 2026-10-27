package main

import (
	"encoding/binary"
	"errors"
)

// Tunnel message types (docs/remote-control.md in LoopCtrl, "Tunnel protocol").
const (
	frameOpen   byte = 1
	frameData   byte = 2
	frameEnd    byte = 3
	frameReset  byte = 4
	frameWindow byte = 5
)

const (
	// maxFrame is the largest DATA payload either side sends.
	maxFrame = 32 * 1024
	// initialWindow is the credit each side starts with, per stream and direction.
	initialWindow = 256 * 1024
)

var errShortFrame = errors.New("tunnel: message shorter than its header")

func encodeFrame(kind byte, stream uint32, payload []byte) []byte {
	b := make([]byte, 5+len(payload))
	b[0] = kind
	binary.BigEndian.PutUint32(b[1:5], stream)
	copy(b[5:], payload)
	return b
}

func decodeFrame(b []byte) (kind byte, stream uint32, payload []byte, err error) {
	if len(b) < 5 {
		return 0, 0, nil, errShortFrame
	}
	return b[0], binary.BigEndian.Uint32(b[1:5]), b[5:], nil
}

func windowPayload(n uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], n)
	return b[:]
}
