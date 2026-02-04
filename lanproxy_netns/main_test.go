package main

import (
	"net"
	"testing"
)

func TestParseAllowListWildcard(t *testing.T) {
	nets, err := parseAllowList("*")
	if err != nil {
		t.Fatalf("parseAllowList(*): %v", err)
	}
	if len(nets) != 2 {
		t.Fatalf("expected 2 nets, got %d", len(nets))
	}
	ip4 := net.ParseIP("8.8.8.8")
	ip6 := net.ParseIP("2001:db8::1")
	if ip4 == nil || ip6 == nil {
		t.Fatal("failed to parse test IPs")
	}

	var has4, has6 bool
	for _, n := range nets {
		if n.Contains(ip4) {
			has4 = true
		}
		if n.Contains(ip6) {
			has6 = true
		}
	}
	if !has4 || !has6 {
		t.Fatalf("wildcard should include both IPv4 and IPv6 (has4=%v has6=%v)", has4, has6)
	}
}
