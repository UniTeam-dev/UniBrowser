# «Через Mac»: direct connection by public IP + own relay server

Problem (2026-10-19): from cellular, the phone reaches the Mac only through n0's
public iroh relays, and the network freezes TLS to them after ~3 KB (DPI on
foreign hosting). Result: 30–80 s to the first page. ilja's home has a public
(«белый») IP.

## A. Direct by public IP (main path at home)

- Mac iroh endpoint binds a fixed UDP port (setting, default 47802) instead of a
  random one, so a router port forward can point at it. Check how iroh 1.0.2's
  `bindAddr` interacts with its IPv4/IPv6 sockets and keep both working.
- Mac setting «Внешний адрес» (Settings → iPhone, and the iPhone… window): an IPv4
  address or a DNS name (DDNS), optional `:port` (default = the fixed port).
  It is added to the addresses the Mac gives the phone (QR payload, and the
  addresses refreshed from every Mac answer). A name is resolved on the phone
  before each connect attempt (A/AAAA), so a changing home IP keeps working.
- iroh's own port mapping (UPnP/NAT-PMP/PCP) stays on; the docs still tell the
  user to forward the port by hand.
- The UI shows the Mac's LAN address and the port to forward, and, after the next
  successful phone connection, which path it used («Напрямую через внешний адрес»
  / «Напрямую» / «Через сервер связи»).
- `docs/via-mac-direct.md` (Russian): how to check the IP is public (router WAN
  address = 2ip.ru), how to forward UDP <port> to the Mac (generic steps plus
  Keenetic, TP-Link, ASUS), giving the Mac a fixed LAN address (DHCP
  reservation), DDNS (KeenDNS etc.), and how to test from cellular.

## B. Own relay server (fallback when the Mac isn't home, or the IP isn't public)

- Mac setting «Свой сервер связи» (URL, empty = n0's servers). When set, the Mac
  endpoint binds with `RelayMode.custom(RelayMap.fromUrls([url]))`.
- The Mac's home relay URL already travels to the phone (QR `relayURL`); it must
  also be refreshed from Mac answers. When the Mac's relay is not one of n0's,
  the phone binds its own endpoint with the same custom relay map (rebinds when it
  changes), so it never depends on n0's relays for this Mac.
- `docs/via-mac-relay.md` (Russian): running `iroh-relay` matching iroh 1.0.2 on a
  VPS (Docker image or `cargo install`), a working config file (verify every key
  against the iroh-relay 1.0.x source), Let's Encrypt, open ports, systemd unit,
  how to test, and choosing a host whose traffic isn't throttled. Ship the config
  and unit as files under `docs/via-mac-relay/`.

## Verification

Both apps build, `scripts/merge_check.swift` passes. In a simulator paired with an
isolated Mac copy: (A) with the external address set to the Mac's LAN IP:port and
the n0 relays disabled for the test, the phone connects directly and loads a page;
a DNS name works; (B) a local `iroh-relay --dev` (Docker) as the custom server:
with direct paths blocked for the test, the link goes through it and pages load.
