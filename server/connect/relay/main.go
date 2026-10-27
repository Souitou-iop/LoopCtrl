// Command loopctrl-relay is a LoopCtrl relay: invite enrollment, and a reverse
// tunnel that gives every enrolled phone a public HTTPS address.
//
// A phone signs in with its own Ed25519 key and keeps one WebSocket open
// (GET /v1/device/tunnel). Requests to the phone's public address travel down
// that WebSocket to the phone's HTTP server unchanged and the response comes
// back the same way, so a browser or an agent sees exactly what it would see
// on the phone's LAN address. Pairing and the protocol v1 envelope stay end
// to end; the relay never opens them.
//
// The contracts are LoopCtrl's docs/relay-enrollment.md (enrollment, sign-in)
// and docs/remote-control.md (tunnel). Device records (public keys only) are
// kept in a JSON state file; codes, tokens and tunnels live in memory.
package main

import (
	"context"
	cryptotls "crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	listen := flag.String("listen", env("LOOPCTRL_RELAY_LISTEN", "127.0.0.1:8787"), "address to serve on")
	extraHTTP := flag.String("http-listen", env("LOOPCTRL_RELAY_HTTP_LISTEN", ""),
		"an additional plain-HTTP address (useful with -tls-cert for local testing)")
	publicServer := flag.String("public-server", env("LOOPCTRL_RELAY_PUBLIC_SERVER", ""),
		"how phones reach this relay, host[:port][/path]; every signature is bound to it")
	deviceDomain := flag.String("device-domain", env("LOOPCTRL_RELAY_DEVICE_DOMAIN", ""),
		"give each phone <slug>.<device-domain> (needs wildcard DNS and a wildcard certificate)")
	pathRouting := flag.String("path-routing", env("LOOPCTRL_RELAY_PATH_ROUTING", "auto"),
		"serve phones at <public-server>/d/<slug>/: on, off, or auto (on unless -device-domain is set)")
	scheme := flag.String("public-scheme", env("LOOPCTRL_RELAY_PUBLIC_SCHEME", "https"), "scheme of the public addresses")
	organization := flag.String("organization", env("LOOPCTRL_RELAY_ORGANIZATION", "LoopCtrl Relay"), "default organization")
	stateFilePath := flag.String("state-file", env("LOOPCTRL_RELAY_STATE_FILE", ""), "JSON file for enrolled devices")
	certFile := flag.String("tls-cert", env("LOOPCTRL_RELAY_TLS_CERT", ""), "serve TLS with this PEM certificate")
	keyFile := flag.String("tls-key", env("LOOPCTRL_RELAY_TLS_KEY", ""), "and this PEM key")
	trusted := flag.String("trusted-proxies", env("LOOPCTRL_RELAY_TRUSTED_PROXIES", "127.0.0.1/32,::1/128"),
		"networks whose X-Real-IP header is believed")
	healthcheck := flag.Bool("healthcheck", false, "check GET /healthz on -listen and exit (for container health checks)")
	flag.Parse()
	if *healthcheck {
		os.Exit(checkHealth(*listen, *certFile != ""))
	}
	eventLog = os.Getenv("LOOPCTRL_RELAY_EVENT_LOG") == "1"

	token := os.Getenv("LOOPCTRL_RELAY_OPERATOR_TOKEN")
	if len(token) < 24 {
		fatal("LOOPCTRL_RELAY_OPERATOR_TOKEN must be set to at least 24 characters")
	}
	if *publicServer == "" {
		fatal("-public-server (or LOOPCTRL_RELAY_PUBLIC_SERVER) is required")
	}
	if (*certFile == "") != (*keyFile == "") {
		fatal("-tls-cert and -tls-key go together")
	}
	cfg := config{deviceDomain: strings.ToLower(strings.Trim(*deviceDomain, ".")), publicScheme: *scheme}
	switch *pathRouting {
	case "auto":
		cfg.pathRouting = cfg.deviceDomain == ""
	case "on", "1", "true":
		cfg.pathRouting = true
	case "off", "0", "false":
	default:
		fatal("-path-routing must be on, off or auto")
	}
	for _, p := range strings.Split(*trusted, ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(p)
		if err != nil {
			fatal("-trusted-proxies: " + err.Error())
		}
		cfg.trustedHosts = append(cfg.trustedHosts, prefix)
	}

	st, err := newState(*publicServer, token, *organization, *stateFilePath)
	if err != nil {
		fatal(err.Error())
	}
	handler := &relay{st: st, cfg: cfg}
	servers := []*http.Server{newServer(*listen, handler)}
	if *extraHTTP != "" {
		servers = append(servers, newServer(*extraHTTP, handler))
	}

	mode := "path routing"
	if cfg.deviceDomain != "" {
		mode = "phones at <slug>." + cfg.deviceDomain
		if cfg.pathRouting {
			mode += " and path routing"
		}
	} else if !cfg.pathRouting {
		mode = "no public addresses"
	}
	errs := make(chan error, len(servers))
	for i, srv := range servers {
		tls := i == 0 && *certFile != ""
		scheme := map[bool]string{true: "https", false: "http"}[tls]
		log.Printf("LoopCtrl relay (API v%d, tunnel v1) on %s://%s as %s, %s; secrets are never logged",
			apiVersion, scheme, srv.Addr, st.server, mode)
		go func(srv *http.Server, tls bool) {
			if tls {
				errs <- srv.ListenAndServeTLS(*certFile, *keyFile)
			} else {
				errs <- srv.ListenAndServe()
			}
		}(srv, tls)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			fatal(err.Error())
		}
	case <-stop:
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, srv := range servers {
		_ = srv.Shutdown(ctx)
	}
}

func checkHealth(addr string, tls bool) int {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	scheme := map[bool]string{true: "https", false: "http"}[tls]
	client := &http.Client{Timeout: 4 * time.Second, Transport: &http.Transport{
		// The certificate is for the public name, not for loopback.
		TLSClientConfig: &cryptotls.Config{InsecureSkipVerify: true}, //nolint:gosec
	}}
	resp, err := client.Get(scheme + "://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func newServer(addr string, h http.Handler) *http.Server {
	// No write timeout: a video stream lasts as long as someone watches.
	return &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 2 * time.Minute}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "loopctrl-relay:", msg)
	os.Exit(2)
}
