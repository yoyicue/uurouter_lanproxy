// lanproxy - an explicit HTTP proxy designed to run as a "LAN device" (netns/veth)
// so that uuplugin's PREROUTING/iifname(br-lan) rules can match and accelerate it.

package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	defaultAllow    = "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
	headerTimeout   = 30 * time.Second
	httpBodyTimeout = 30 * time.Second
	copyBufSize     = 32 * 1024
	maxIdleConns    = 64
	maxIdlePerHost  = 8
	idleConnTimeout = 90 * time.Second
)

var (
	listenAddr     string
	allow          string
	connectTimeout time.Duration
	idleTimeout    time.Duration
	verbose        bool

	allowedNets []*net.IPNet
	transport   *http.Transport

	writerPool = sync.Pool{
		New: func() any { return bufio.NewWriterSize(io.Discard, copyBufSize) },
	}
	copyBufPool = sync.Pool{
		New: func() any { return make([]byte, copyBufSize) },
	}
)

func init() {
	flag.StringVar(&listenAddr, "listen", "0.0.0.0:8888", "Listen address (inside netns)")
	flag.StringVar(&allow, "allow", defaultAllow, "Allowed client CIDRs/IPs (comma-separated)")
	flag.DurationVar(&connectTimeout, "connect-timeout", 15*time.Second, "Upstream connect timeout")
	flag.DurationVar(&idleTimeout, "idle-timeout", 0, "Idle timeout for tunnels (0 = disabled)")
	flag.BoolVar(&verbose, "verbose", false, "Verbose logging")
}

func main() {
	flag.Parse()

	var err error
	allowedNets, err = parseAllowList(allow)
	if err != nil {
		log.Fatalf("Invalid -allow: %v", err)
	}
	transport = newUpstreamTransport(connectTimeout, httpBodyTimeout)

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("Listen %s: %v", listenAddr, err)
	}
	log.Printf("lanproxy listening on %s (allow=%q)", listenAddr, allow)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("Accept: %v", err)
			continue
		}
		go handleConn(c)
	}
}

func handleConn(c net.Conn) {
	defer c.Close()

	clientIP, _, err := net.SplitHostPort(c.RemoteAddr().String())
	if err != nil {
		if verbose {
			log.Printf("Bad RemoteAddr %q: %v", c.RemoteAddr().String(), err)
		}
		return
	}
	ip := net.ParseIP(clientIP)
	if ip == nil {
		if verbose {
			log.Printf("Bad client IP %q", clientIP)
		}
		return
	}
	if !isAllowed(ip) {
		log.Printf("Reject client %s (not in allow list)", ip)
		return
	}

	_ = c.SetReadDeadline(time.Now().Add(headerTimeout))
	br := bufio.NewReader(c)

	for {
		req, err := http.ReadRequest(br)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return
			}
			if verbose {
				log.Printf("ReadRequest from %s: %v", ip, err)
			}
			return
		}
		_ = c.SetReadDeadline(time.Time{})

		if req.Method == http.MethodConnect {
			handleConnect(c, br, ip, req)
			return // CONNECT turns into a tunnel; no more HTTP requests on this conn
		}

		closeAfter, err := handleHTTP(c, ip, req)
		if err != nil {
			if verbose {
				log.Printf("HTTP from %s: %v", ip, err)
			}
			return
		}
		if closeAfter {
			return
		}

		// Keep-alive: continue reading more requests unless client asked to close.
		if shouldClose(req) {
			return
		}
		_ = c.SetReadDeadline(time.Now().Add(headerTimeout))
	}
}

func handleConnect(clientConn net.Conn, clientReader *bufio.Reader, clientIP net.IP, req *http.Request) {
	target := req.Host
	if target == "" {
		_ = sendError(clientConn, http.StatusBadRequest)
		return
	}
	if !strings.Contains(target, ":") {
		target += ":443"
	}
	if verbose {
		log.Printf("[CONNECT] %s -> %s", clientIP, target)
	}

	d := &net.Dialer{Timeout: connectTimeout, KeepAlive: 30 * time.Second}
	up, err := d.Dial("tcp", target)
	if err != nil {
		if verbose {
			log.Printf("Dial %s: %v", target, err)
		}
		_ = sendError(clientConn, http.StatusBadGateway)
		return
	}
	defer up.Close()

	// Switch/clients expect this exact status line.
	if _, err := io.WriteString(clientConn, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}

	relayWithBufferedReader(clientConn, clientReader, up, idleTimeout)
}

func handleHTTP(clientConn net.Conn, clientIP net.IP, req *http.Request) (bool, error) {
	targetAddr, err := normalizeProxyRequest(req)
	if err != nil {
		_ = sendError(clientConn, http.StatusBadRequest)
		return true, err
	}

	if verbose {
		log.Printf("[HTTP] %s %s -> %s", clientIP, req.Method, targetAddr)
	}

	// Remove proxy-only headers.
	req.Header.Del("Proxy-Connection")
	req.Header.Del("Proxy-Authenticate")
	req.Header.Del("Proxy-Authorization")

	// Per net/http rules for client requests.
	req.RequestURI = ""

	// If the client asked to close, signal upstream too.
	if shouldClose(req) {
		req.Close = true
	}

	if req.Body != nil && req.Body != http.NoBody {
		req.Body = &deadlineReadCloser{ReadCloser: req.Body, conn: clientConn, idle: httpBodyTimeout}
	}

	resp, err := transport.RoundTrip(req)
	if err != nil {
		_ = sendError(clientConn, http.StatusBadGateway)
		return true, fmt.Errorf("roundtrip %s: %w", targetAddr, err)
	}
	defer resp.Body.Close()

	closeAfter := shouldClose(req) || resp.Close
	if closeAfter {
		resp.Close = true
		resp.Header.Set("Connection", "close")
	}

	bw := writerPool.Get().(*bufio.Writer)
	bw.Reset(clientConn)
	defer func() {
		bw.Reset(io.Discard)
		writerPool.Put(bw)
	}()

	var w io.Writer = bw
	if httpBodyTimeout > 0 {
		w = &deadlineWriter{w: bw, conn: clientConn, idle: httpBodyTimeout}
	}

	if err := resp.Write(w); err != nil {
		return true, err
	}
	if err := bw.Flush(); err != nil {
		return true, err
	}
	return closeAfter, nil
}

func normalizeProxyRequest(req *http.Request) (string, error) {
	if req.URL == nil {
		return "", errors.New("missing URL")
	}

	targetHost, targetPort, err := resolveHTTPUpstream(req)
	if err != nil {
		return "", err
	}
	targetAddr := net.JoinHostPort(targetHost, targetPort)

	if req.URL.Scheme == "" {
		req.URL.Scheme = "http"
	} else if strings.EqualFold(req.URL.Scheme, "https") {
		// Preserve old behavior: no TLS, but keep 443 if https was specified.
		req.URL.Scheme = "http"
	}
	req.URL.Host = targetAddr
	if req.Host == "" {
		req.Host = targetHost
	}
	return targetAddr, nil
}

func newUpstreamTransport(connectTimeout, idle time.Duration) *http.Transport {
	dialer := &net.Dialer{Timeout: connectTimeout, KeepAlive: 30 * time.Second}
	return &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialWithDeadline(ctx, dialer, network, addr, idle)
		},
		DisableCompression:    true,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          maxIdleConns,
		MaxIdleConnsPerHost:   maxIdlePerHost,
		IdleConnTimeout:       idleConnTimeout,
		ResponseHeaderTimeout: headerTimeout,
	}
}

func dialWithDeadline(ctx context.Context, dialer *net.Dialer, network, addr string, idle time.Duration) (net.Conn, error) {
	c, err := dialer.DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	if idle <= 0 {
		return c, nil
	}
	return &deadlineConn{Conn: c, idle: idle}, nil
}

func resolveHTTPUpstream(req *http.Request) (host, port string, err error) {
	// Proxy requests commonly use absolute-form (URL has Scheme+Host).
	h := ""
	scheme := ""
	if req.URL != nil {
		h = req.URL.Host
		scheme = req.URL.Scheme
	}
	if h == "" {
		h = req.Host
	}
	if h == "" {
		return "", "", errors.New("missing Host")
	}

	host, port, err = splitHostPortDefault(h, defaultPortForScheme(scheme))
	if err != nil {
		return "", "", err
	}
	return host, port, nil
}

func defaultPortForScheme(scheme string) string {
	switch strings.ToLower(scheme) {
	case "https":
		return "443"
	default:
		return "80"
	}
}

func splitHostPortDefault(hostport, defaultPort string) (host, port string, err error) {
	if strings.HasPrefix(hostport, "http://") || strings.HasPrefix(hostport, "https://") {
		u, err := url.Parse(hostport)
		if err != nil {
			return "", "", err
		}
		hostport = u.Host
	}

	if strings.Contains(hostport, ":") {
		h, p, err := net.SplitHostPort(hostport)
		if err == nil {
			return h, p, nil
		}
		// If SplitHostPort fails, it might be a host without a port but with ':' (unlikely for IPv6 here).
	}
	return hostport, defaultPort, nil
}

func relayWithBufferedReader(down net.Conn, downReader *bufio.Reader, up net.Conn, idle time.Duration) {
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		buf := copyBufPool.Get().([]byte)
		defer copyBufPool.Put(buf)

		r := io.Reader(downReader)
		w := io.Writer(up)
		if idle > 0 {
			r = &deadlineReader{r: downReader, conn: down, idle: idle}
			w = &deadlineWriter{w: up, conn: up, idle: idle}
		}
		_, _ = io.CopyBuffer(w, r, buf) // include bytes already buffered by ReadRequest
		if tc, ok := up.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
	}()

	go func() {
		defer wg.Done()
		buf := copyBufPool.Get().([]byte)
		defer copyBufPool.Put(buf)

		r := io.Reader(up)
		w := io.Writer(down)
		if idle > 0 {
			r = &deadlineReader{r: up, conn: up, idle: idle}
			w = &deadlineWriter{w: down, conn: down, idle: idle}
		}
		_, _ = io.CopyBuffer(w, r, buf)
		if tc, ok := down.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
	}()

	wg.Wait()
}

type deadlineConn struct {
	net.Conn
	idle      time.Duration
	lastRead  int64
	lastWrite int64
}

func (d *deadlineConn) Read(p []byte) (int, error) {
	if d.idle > 0 {
		now := time.Now()
		last := atomic.LoadInt64(&d.lastRead)
		if last == 0 || now.Sub(time.Unix(0, last)) > d.idle/2 {
			_ = d.Conn.SetReadDeadline(now.Add(d.idle))
			atomic.StoreInt64(&d.lastRead, now.UnixNano())
		}
	}
	return d.Conn.Read(p)
}

func (d *deadlineConn) Write(p []byte) (int, error) {
	if d.idle > 0 {
		now := time.Now()
		last := atomic.LoadInt64(&d.lastWrite)
		if last == 0 || now.Sub(time.Unix(0, last)) > d.idle/2 {
			_ = d.Conn.SetWriteDeadline(now.Add(d.idle))
			atomic.StoreInt64(&d.lastWrite, now.UnixNano())
		}
	}
	return d.Conn.Write(p)
}

type deadlineReader struct {
	r    io.Reader
	conn net.Conn
	idle time.Duration
	last time.Time
}

func (d *deadlineReader) Read(p []byte) (int, error) {
	if d.idle > 0 {
		now := time.Now()
		if d.last.IsZero() || now.Sub(d.last) > d.idle/2 {
			_ = d.conn.SetReadDeadline(now.Add(d.idle))
			d.last = now
		}
	}
	return d.r.Read(p)
}

type deadlineWriter struct {
	w    io.Writer
	conn net.Conn
	idle time.Duration
	last time.Time
}

func (d *deadlineWriter) Write(p []byte) (int, error) {
	if d.idle > 0 {
		now := time.Now()
		if d.last.IsZero() || now.Sub(d.last) > d.idle/2 {
			_ = d.conn.SetWriteDeadline(now.Add(d.idle))
			d.last = now
		}
	}
	return d.w.Write(p)
}

type deadlineReadCloser struct {
	io.ReadCloser
	conn net.Conn
	idle time.Duration
	last time.Time
}

func (d *deadlineReadCloser) Read(p []byte) (int, error) {
	if d.idle > 0 {
		now := time.Now()
		if d.last.IsZero() || now.Sub(d.last) > d.idle/2 {
			_ = d.conn.SetReadDeadline(now.Add(d.idle))
			d.last = now
		}
	}
	return d.ReadCloser.Read(p)
}

func parseAllowList(s string) ([]*net.IPNet, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("empty allow list")
	}
	if s == "*" {
		_, all4, _ := net.ParseCIDR("0.0.0.0/0")
		_, all6, _ := net.ParseCIDR("::/0")
		return []*net.IPNet{all4, all6}, nil
	}

	var out []*net.IPNet
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if strings.Contains(part, "/") {
			_, n, err := net.ParseCIDR(part)
			if err != nil {
				return nil, fmt.Errorf("parse CIDR %q: %w", part, err)
			}
			out = append(out, n)
			continue
		}

		ip := net.ParseIP(part)
		if ip == nil {
			return nil, fmt.Errorf("parse IP %q: invalid", part)
		}
		bits := 128
		if ip.To4() != nil {
			ip = ip.To4()
			bits = 32
		}
		mask := net.CIDRMask(bits, bits)
		out = append(out, &net.IPNet{IP: ip, Mask: mask})
	}
	if len(out) == 0 {
		return nil, errors.New("empty allow list after parsing")
	}
	return out, nil
}

func isAllowed(ip net.IP) bool {
	for _, n := range allowedNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

func shouldClose(req *http.Request) bool {
	// For HTTP/1.0 without explicit keep-alive we close by default.
	if req.ProtoMajor == 1 && req.ProtoMinor == 0 {
		return !strings.EqualFold(req.Header.Get("Connection"), "keep-alive")
	}
	return strings.EqualFold(req.Header.Get("Connection"), "close")
}

func sendError(conn net.Conn, code int) error {
	status := http.StatusText(code)
	if status == "" {
		status = "Error"
	}
	_, err := fmt.Fprintf(conn, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", code, status)
	return err
}
