// mdns-reflector: standalone mDNS bridge for Windows hosts running
// VectorIntelligence in Docker.  It replicates the exact mDNS behaviour of
// Wire-Pod's built-in mdnshandler (register/shutdown loop every 30 s,
// reactive broadcast when Vector appears) but runs natively on the Windows
// network stack, bypassing WSL2's multicast limitations.
//
// Build (cross-compile inside Docker):
//   GOOS=windows GOARCH=amd64 go build -o /output/windows-mdns.exe ./shared/mdns-reflector.go
//
// Usage:
//   windows-mdns.exe                        (auto-detect IP)
//   windows-mdns.exe -botinfo path/to/botSdkInfo.json

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/kercre123/zeroconf"
)

// ── Configuration ────────────────────────────────────────────────────────────

const (
	// How often the mDNS registration is destroyed and recreated (matches
	// wire-pod's mdnshandler.go loop timer).
	reRegisterInterval = 30 * time.Second

	// Service parameters — must match wire-pod exactly.
	instanceName = "escapepod"
	serviceType  = "_app-proto._tcp"
	domain       = "local."
	servicePort  = 8084

	// The mDNS service type that Vector himself broadcasts when he boots.
	vectorServiceType = "_ankivector._tcp"
)

var txtRecords = []string{"txtv=0", "lo=1", "la=2"}

// ── IP detection (same algorithm as wire-pod's vars.GetOutboundIP) ───────────

func getOutboundIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		log.Println("[mdns-reflector] WARN: not connected to a network:", err)
		return "0.0.0.0"
	}
	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP.String()
}

// ── botSdkInfo.json updater ──────────────────────────────────────────────────

// BotInfo mirrors the minimal structure of botSdkInfo.json.
type BotInfo struct {
	Robots []struct {
		Esn       string `json:"esn"`
		IPAddress string `json:"ip_address"`
		// keep other fields intact
	} `json:"robots"`
}

func updateBotInfo(path string, vectorIP string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return // file doesn't exist yet — nothing to update
	}

	// Parse into a generic map so we preserve ALL fields, not just the ones
	// we model in BotInfo.
	var data map[string]interface{}
	if err := json.Unmarshal(raw, &data); err != nil {
		log.Printf("[mdns-reflector] WARN: failed to parse %s: %v\n", path, err)
		return
	}

	robots, ok := data["robots"].([]interface{})
	if !ok || len(robots) == 0 {
		return
	}
	first, ok := robots[0].(map[string]interface{})
	if !ok {
		return
	}

	oldIP, _ := first["ip_address"].(string)
	if oldIP == vectorIP {
		return // nothing changed
	}

	first["ip_address"] = vectorIP
	out, err := json.Marshal(data)
	if err != nil {
		return
	}
	if err := os.WriteFile(path, out, 0644); err != nil {
		log.Printf("[mdns-reflector] WARN: failed to write %s: %v\n", path, err)
		return
	}
	log.Printf("[mdns-reflector] Vector IP updated: %s -> %s\n", oldIP, vectorIP)
}

// ── Vector discovery (listen for _ankivector._tcp) ───────────────────────────

func watchForVector(botInfoPath string, triggerReRegister chan<- struct{}) {
	for {
		resolver, err := zeroconf.NewResolver(nil)
		if err != nil {
			log.Printf("[mdns-reflector] WARN: resolver error: %v\n", err)
			time.Sleep(5 * time.Second)
			continue
		}

		entries := make(chan *zeroconf.ServiceEntry)
		ctx, cancel := context.WithTimeout(context.Background(), 80*time.Second)

		if err := resolver.Browse(ctx, vectorServiceType, domain, entries); err != nil {
			log.Printf("[mdns-reflector] WARN: browse error: %v\n", err)
			cancel()
			time.Sleep(5 * time.Second)
			continue
		}

		for entry := range entries {
			if strings.Contains(entry.Service, "ankivector") {
				vectorIP := ""
				if len(entry.AddrIPv4) > 0 {
					vectorIP = entry.AddrIPv4[0].String()
				}
				log.Printf("[mdns-reflector] Vector discovered on network: %s (%s)\n",
					entry.HostName, vectorIP)

				// Update botSdkInfo.json with Vector's current IP
				if vectorIP != "" && botInfoPath != "" {
					updateBotInfo(botInfoPath, vectorIP)
				}

				// Trigger immediate mDNS re-registration (like PostmDNSNow)
				select {
				case triggerReRegister <- struct{}{}:
				default:
				}
			}
		}
		cancel()
	}
}

// ── Main mDNS registration loop ─────────────────────────────────────────────

func main() {
	log.SetFlags(log.Ldate | log.Ltime)
	log.Println("[mdns-reflector] Starting mDNS reflector for VectorIntelligence...")

	// Determine botSdkInfo.json path
	botInfoPath := ""
	for i, arg := range os.Args {
		if arg == "-botinfo" && i+1 < len(os.Args) {
			botInfoPath = os.Args[i+1]
		}
	}
	if botInfoPath == "" {
		// Default: look in ./vector-data/jdocs/ (relative to .exe location)
		exePath, _ := os.Executable()
		exeDir := filepath.Dir(exePath)
		candidate := filepath.Join(exeDir, "vector-data", "jdocs", "botSdkInfo.json")
		if _, err := os.Stat(candidate); err == nil {
			botInfoPath = candidate
		}
	}
	if botInfoPath != "" {
		log.Printf("[mdns-reflector] Will update botSdkInfo.json at: %s\n", botInfoPath)
	}

	// Channel to trigger immediate re-registration
	triggerReRegister := make(chan struct{}, 1)

	// Start Vector discovery in background
	go watchForVector(botInfoPath, triggerReRegister)

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	var server *zeroconf.Server
	var mu sync.Mutex

	registerMDNS := func() *zeroconf.Server {
		ip := getOutboundIP()
		s, err := zeroconf.RegisterProxy(
			instanceName,
			serviceType,
			domain,
			servicePort,
			instanceName,       // hostname
			[]string{ip},       // IPs
			txtRecords,         // TXT records
			nil,                // interfaces (all)
		)
		if err != nil {
			log.Printf("[mdns-reflector] WARN: failed to register mDNS: %v\n", err)
			return nil
		}
		log.Printf("[mdns-reflector] Broadcasting escapepod.local -> %s\n", ip)
		return s
	}

	shutdownServer := func() {
		mu.Lock()
		defer mu.Unlock()
		if server != nil {
			server.Shutdown()
			server = nil
		}
	}

	// Main loop: register, wait 30s (or trigger), shutdown, repeat.
	go func() {
		for {
			mu.Lock()
			server = registerMDNS()
			mu.Unlock()

			// Wait for either the timer or a forced re-registration trigger
			select {
			case <-time.After(reRegisterInterval):
			case <-triggerReRegister:
				log.Println("[mdns-reflector] Immediate re-registration triggered (Vector detected)")
			}

			shutdownServer()
			time.Sleep(333 * time.Millisecond) // brief pause before re-register
		}
	}()

	// Block until SIGINT/SIGTERM
	sig := <-sigCh
	fmt.Printf("\n[mdns-reflector] Received %v, shutting down...\n", sig)
	shutdownServer()
	log.Println("[mdns-reflector] Goodbye!")
}
