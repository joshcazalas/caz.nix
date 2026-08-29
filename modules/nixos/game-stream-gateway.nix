{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.gameStreamGateway;
  interfaceName = "wg-game";
  policyChain = "caz-game-stream";
  guardChain = "caz-game-stream-guard";
  secretName = "game-stream-gateway/config";
  productionConfiguration = cfg._testConfigFile == null;
  configurationFile =
    if productionConfiguration then config.sops.secrets.${secretName}.path else cfg._testConfigFile;

  gatewayControl = pkgs.writeShellApplication {
    name = "caz-game-stream-gateway";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.iproute2
      pkgs.iptables
      pkgs.wireguard-tools
    ];
    text = ''
      die() {
        echo "game-stream-gateway: $1" >&2
        exit 1
      }

      usage() {
        echo "usage: caz-game-stream-gateway {validate|apply|remove|report} CONFIG INTERFACE LISTEN_PORT" >&2
        exit 2
      }

      [[ $# -eq 4 ]] || usage

      action="$1"
      configuration_file="$2"
      interface_name="$3"
      listen_port="$4"
      policy_chain=${lib.escapeShellArg policyChain}
      guard_chain=${lib.escapeShellArg guardChain}

      interface_values() {
        local wanted="$1"
        awk -F= -v wanted="$wanted" '
          function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
          }
          /^[[:space:]]*\[Interface\][[:space:]]*$/ { in_interface = 1; next }
          /^[[:space:]]*\[/ { in_interface = 0; next }
          in_interface && index($0, "=") {
            key = trim($1)
            value = substr($0, index($0, "=") + 1)
            if (tolower(key) == tolower(wanted)) print trim(value)
          }
        ' "$configuration_file"
      }

      peer_values() {
        local wanted="$1"
        awk -F= -v wanted="$wanted" '
          function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
          }
          /^[[:space:]]*\[Peer\][[:space:]]*$/ { in_peer = 1; next }
          /^[[:space:]]*\[/ { in_peer = 0; next }
          in_peer && index($0, "=") {
            key = trim($1)
            value = substr($0, index($0, "=") + 1)
            if (tolower(key) == tolower(wanted)) print trim(value)
          }
        ' "$configuration_file"
      }

      peer_values_at() {
        local peer_number="$1"
        local wanted="$2"
        awk -F= -v peer_number="$peer_number" -v wanted="$wanted" '
          function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
          }
          /^[[:space:]]*\[Peer\][[:space:]]*$/ {
            current_peer++
            in_peer = current_peer == peer_number
            next
          }
          /^[[:space:]]*\[/ { in_peer = 0; next }
          in_peer && index($0, "=") {
            key = trim($1)
            value = substr($0, index($0, "=") + 1)
            if (tolower(key) == tolower(wanted)) print trim(value)
          }
        ' "$configuration_file"
      }

      validate_key() {
        local key="$1"
        local decoded_length

        [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
        decoded_length=$(printf '%s' "$key" | base64 --decode 2>/dev/null | wc -c)
        [[ "$decoded_length" -eq 32 ]]
      }

      validate_exact_ipv4_route() {
        local route="$1"
        local address
        local octet
        local -a octets

        [[ "$route" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || return 1
        address="''${route%/32}"
        IFS=. read -r -a octets <<<"$address"
        for octet in "''${octets[@]}"; do
          (( 10#$octet <= 255 )) || return 1
        done
      }

      validate_configuration() {
        local peer_number
        local -a public_keys=()
        local -a allowed_ips=()
        local -a peer_public_keys
        local -a peer_allowed_ips
        local -a peer_preshared_keys
        local -a peer_keepalives

        [[ -r "$configuration_file" ]] || die "the opaque configuration is unavailable"
        [[ "$interface_name" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die "the interface name is invalid"
        [[ "$listen_port" =~ ^[0-9]+$ ]] || die "the listener port is invalid"

        if grep -Eqi '^[[:space:]]*(SaveConfig|DNS|Table|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=' "$configuration_file"; then
          die "the opaque configuration contains a forbidden wg-quick directive"
        fi
        if ! awk -F= '
          function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
          }
          /^[[:space:]]*($|#|;)/ { next }
          /^[[:space:]]*\[Interface\][[:space:]]*$/ { section = "interface"; next }
          /^[[:space:]]*\[Peer\][[:space:]]*$/ { section = "peer"; next }
          index($0, "=") {
            key = tolower(trim($1))
            if (section == "interface" && key ~ /^(address|privatekey|listenport)$/) next
            if (section == "peer" && key ~ /^(publickey|presharedkey|allowedips|persistentkeepalive)$/) next
          }
          { exit 1 }
        ' "$configuration_file"; then
          die "the opaque configuration contains an unsupported directive"
        fi

        [[ $(grep -Eic '^[[:space:]]*\[Interface\][[:space:]]*$' "$configuration_file") -eq 1 ]] ||
          die "the opaque configuration must contain one interface"
        [[ $(grep -Eic '^[[:space:]]*\[Peer\][[:space:]]*$' "$configuration_file") -eq 2 ]] ||
          die "the opaque configuration must contain exactly two role peers"

        mapfile -t interface_addresses < <(interface_values Address)
        mapfile -t private_keys < <(interface_values PrivateKey)
        mapfile -t configured_ports < <(interface_values ListenPort)

        [[ ''${#interface_addresses[@]} -eq 1 ]] ||
          die "the gateway interface must have one address"
        validate_exact_ipv4_route "''${interface_addresses[0]}" ||
          die "the gateway interface address must be an exact IPv4 /32"
        [[ ''${#configured_ports[@]} -eq 1 && "''${configured_ports[0]}" == "$listen_port" ]] ||
          die "the encrypted listener does not match the reviewed public listener"
        if [[ ''${#private_keys[@]} -ne 1 ]] || ! validate_key "''${private_keys[0]}"; then
          die "the gateway private key is missing or malformed"
        fi
        for peer_number in 1 2; do
          mapfile -t peer_public_keys < <(peer_values_at "$peer_number" PublicKey)
          mapfile -t peer_allowed_ips < <(peer_values_at "$peer_number" AllowedIPs)
          mapfile -t peer_preshared_keys < <(peer_values_at "$peer_number" PresharedKey)
          mapfile -t peer_keepalives < <(peer_values_at "$peer_number" PersistentKeepalive)

          [[ ''${#peer_public_keys[@]} -eq 1 ]] ||
            die "each role peer must contain exactly one public key"
          [[ ''${#peer_allowed_ips[@]} -eq 1 ]] ||
            die "each role peer must contain exactly one route"
          [[ ''${#peer_preshared_keys[@]} -le 1 ]] ||
            die "a role peer repeats its optional preshared key"
          [[ ''${#peer_keepalives[@]} -le 1 ]] ||
            die "a role peer repeats its optional keepalive"
          if [[ ''${#peer_preshared_keys[@]} -eq 1 ]]; then
            validate_key "''${peer_preshared_keys[0]}" ||
              die "a role peer preshared key is malformed"
          fi
          if [[ ''${#peer_keepalives[@]} -eq 1 ]]; then
            if ! [[ "''${peer_keepalives[0]}" =~ ^[0-9]+$ ]] ||
              (( 10#''${peer_keepalives[0]} > 65535 )); then
              die "a role peer keepalive is invalid"
            fi
          fi

          public_keys+=("''${peer_public_keys[0]}")
          allowed_ips+=("''${peer_allowed_ips[0]}")
        done

        for key in "''${public_keys[@]}"; do
          validate_key "$key" || die "a role peer public key is malformed"
        done
        [[ "''${public_keys[0]}" != "''${public_keys[1]}" ]] ||
          die "the host and client role public keys must be distinct"
        for address in "''${allowed_ips[@]}"; do
          if [[ "$address" == *,* ]] || ! validate_exact_ipv4_route "$address"; then
            die "each role peer route must be one exact IPv4 /32"
          fi
        done
        [[ "''${allowed_ips[0]}" != "''${allowed_ips[1]}" ]] ||
          die "the host and client role routes must be distinct"
        for address in "''${allowed_ips[@]}"; do
          [[ "$address" != "''${interface_addresses[0]}" ]] ||
            die "a role peer route must not equal the gateway address"
        done

      }

      remove_policy() {
        if iptables -w -L "$policy_chain" >/dev/null 2>&1; then
          iptables -w -F "$policy_chain"
          iptables -w -A "$policy_chain" -j DROP
        fi
      }

      ensure_guard() {
        local duplicate_line
        local expected_jump="-A FORWARD -i $interface_name -j $guard_chain"

        if ! iptables -w -L "$guard_chain" >/dev/null 2>&1; then
          iptables -w -N "$guard_chain"
        fi
        # Install the deny rule first, then remove only rules below it. The
        # live chain is never empty and cannot return to broader forwarding.
        iptables -w -I "$guard_chain" 1 -j DROP
        while [[ $(iptables -w -S "$guard_chain" | grep -c "^-A $guard_chain ") -gt 1 ]]; do
          iptables -w -D "$guard_chain" 2
        done

        iptables -w -I FORWARD 1 -i "$interface_name" -j "$guard_chain"
        while [[ $(iptables -w -S FORWARD | grep -c "^$expected_jump$") -gt 1 ]]; do
          duplicate_line=$(iptables -w -S FORWARD | awk -v expected="$expected_jump" '
            $1 == "-A" { rule_number++ }
            $0 == expected { duplicate = rule_number }
            END { print duplicate }
          ')
          iptables -w -D FORWARD "$duplicate_line"
        done
        while iptables -w -C FORWARD -i "$interface_name" -j "$policy_chain" >/dev/null 2>&1; do
          iptables -w -D FORWARD -i "$interface_name" -j "$policy_chain"
        done

        if ! iptables -w -L "$policy_chain" >/dev/null 2>&1; then
          iptables -w -N "$policy_chain"
        fi
        iptables -w -F "$policy_chain"
        iptables -w -A "$policy_chain" -j DROP
      }

      activate_policy() {
        # The leading DROP remains effective until both steady-state rules
        # exist. Removing it is the atomic commit point for the rebuilt policy.
        iptables -w -A "$guard_chain" -j "$policy_chain"
        iptables -w -A "$guard_chain" -j DROP
        iptables -w -D "$guard_chain" 1
      }

      apply_policy() {
        validate_configuration
        mapfile -t allowed_ips < <(peer_values AllowedIPs)

        # The encrypted file has a fixed, documented role order: host first,
        # client second. No key, endpoint, address, or mapping is printed.
        host_address="''${allowed_ips[0]}"
        client_address="''${allowed_ips[1]}"

        ensure_guard
        # An empty policy returns to the guard's unconditional DROP, so a
        # failed or interrupted rebuild remains fail closed.
        iptables -w -F "$policy_chain"
        iptables -w -A "$policy_chain" -m conntrack --ctstate INVALID -j DROP
        iptables -w -A "$policy_chain" \
          -s "$host_address" -d "$client_address" \
          -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -w -A "$policy_chain" \
          -s "$client_address" -d "$host_address" \
          -p tcp -m multiport --dports 47984,47989,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -w -A "$policy_chain" \
          -s "$client_address" -d "$host_address" \
          -p udp -m multiport --dports 47998:48000,48002,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -w -A "$policy_chain" -j DROP
        activate_policy
      }

      policy_is_exact() {
        local host_address="$1"
        local client_address="$2"
        local first_forward_rule
        local first_guard_rule
        local last_guard_rule
        local first_policy_rule
        local last_policy_rule

        iptables -w -C "$guard_chain" -j "$policy_chain" >/dev/null 2>&1 || return 1
        iptables -w -C "$guard_chain" -j DROP >/dev/null 2>&1 || return 1
        iptables -w -C "$policy_chain" -m conntrack --ctstate INVALID -j DROP >/dev/null 2>&1 || return 1
        iptables -w -C "$policy_chain" \
          -s "$host_address" -d "$client_address" \
          -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
        iptables -w -C "$policy_chain" \
          -s "$client_address" -d "$host_address" \
          -p tcp -m multiport --dports 47984,47989,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
        iptables -w -C "$policy_chain" \
          -s "$client_address" -d "$host_address" \
          -p udp -m multiport --dports 47998:48000,48002,48010 \
          -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
        iptables -w -C "$policy_chain" -j DROP >/dev/null 2>&1 || return 1

        [[ $(iptables -w -S "$guard_chain" | grep -c "^-A $guard_chain ") -eq 2 ]] || return 1
        [[ $(iptables -w -S "$policy_chain" | grep -c "^-A $policy_chain ") -eq 5 ]] || return 1
        [[ $(iptables -w -S FORWARD | grep -c "^-A FORWARD -i $interface_name -j $guard_chain$") -eq 1 ]] || return 1
        [[ $(iptables -w -S FORWARD | grep -c "^-A FORWARD -i $interface_name -j $policy_chain$") -eq 0 ]] || return 1

        first_forward_rule=$(iptables -w -S FORWARD | sed -n '2p')
        first_guard_rule=$(iptables -w -S "$guard_chain" | sed -n '2p')
        last_guard_rule=$(iptables -w -S "$guard_chain" | tail -n 1)
        first_policy_rule=$(iptables -w -S "$policy_chain" | sed -n '2p')
        last_policy_rule=$(iptables -w -S "$policy_chain" | tail -n 1)
        [[ "$first_forward_rule" == "-A FORWARD -i $interface_name -j $guard_chain" ]] || return 1
        [[ "$first_guard_rule" == "-A $guard_chain -j $policy_chain" ]] || return 1
        [[ "$last_guard_rule" == "-A $guard_chain -j DROP" ]] || return 1
        [[ "$first_policy_rule" == "-A $policy_chain -m conntrack --ctstate INVALID -j DROP" ]] || return 1
        [[ "$last_policy_rule" == "-A $policy_chain -j DROP" ]]
      }

      report_status() {
        validate_configuration
        mapfile -t configured_addresses < <(interface_values Address)
        mapfile -t configured_routes < <(peer_values AllowedIPs)

        if ! wg show "$interface_name" >/dev/null 2>&1; then
          echo "drifted: WireGuard interface is not active"
          exit 10
        fi
        mapfile -t effective_addresses < <(ip -o -4 address show dev "$interface_name" scope global | awk '{ print $4 }')
        if [[ ''${#effective_addresses[@]} -ne 1 || "''${effective_addresses[0]}" != "''${configured_addresses[0]}" ]]; then
          echo "drifted: effective gateway address differs from the opaque configuration"
          exit 10
        fi
        if [[ $(wg show "$interface_name" peers | wc -l) -ne 2 ]]; then
          echo "drifted: WireGuard peer count differs from the two generic roles"
          exit 10
        fi
        mapfile -t expected_routes < <(printf '%s\n' "''${configured_routes[@]}" | sort)
        mapfile -t effective_routes < <(wg show "$interface_name" allowed-ips | awk '{ print $2 }' | sort)
        if [[ "''${effective_routes[*]}" != "''${expected_routes[*]}" ]]; then
          echo "drifted: effective peer routes differ from the two exact role routes"
          exit 10
        fi
        for route in "''${expected_routes[@]}"; do
          if ! ip -4 route show exact "$route" dev "$interface_name" | grep -q .; then
            echo "drifted: an exact role route is absent from the kernel routing table"
            exit 10
          fi
        done
        if [[ $(wg show "$interface_name" listen-port) != "$listen_port" ]]; then
          echo "drifted: WireGuard listener differs from the reviewed port"
          exit 10
        fi
        if ! policy_is_exact "''${configured_routes[0]}" "''${configured_routes[1]}"; then
          echo "drifted: exact fail-closed forwarding policy differs"
          exit 10
        fi

        current_time=$(date +%s)
        recent_handshakes=0
        while read -r _ latest_handshake; do
          if [[ "$latest_handshake" =~ ^[0-9]+$ ]] && (( latest_handshake > 0 && current_time - latest_handshake < 180 )); then
            recent_handshakes=$((recent_handshakes + 1))
          fi
        done < <(wg show "$interface_name" latest-handshakes)

        if (( recent_handshakes == 0 )); then
          echo "environmental warning: no role peer has a recent handshake"
          exit 30
        fi
        echo "compliant: gateway interface, peer count, listener, and narrow forwarding policy"
      }

      case "$action" in
        validate)
          validate_configuration
          ;;
        apply)
          apply_policy
          ;;
        remove)
          remove_policy
          ;;
        report)
          report_status
          ;;
        *)
          usage
          ;;
      esac
    '';
  };
in
{
  options.homelab.gameStreamGateway = {
    enable = lib.mkEnableOption "the narrowly filtered game-stream WireGuard gateway";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        The single public UDP listener forwarded to this gateway. The opaque
        WireGuard configuration must declare the same value.
      '';
    };

    _testConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      internal = true;
      description = "Test-only throwaway WireGuard configuration override.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.elem interfaceName config.networking.firewall.trustedInterfaces;
        message = "The game-stream WireGuard interface must remain untrusted.";
      }
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "The game-stream gateway policy currently requires the reviewed iptables firewall backend.";
      }
      {
        assertion = config.networking.firewall.checkReversePath == true;
        message = "The game-stream gateway requires strict reverse-path filtering.";
      }
    ];

    sops.secrets.${secretName} = lib.mkIf productionConfiguration {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "gameStreamGatewayConfig";
      mode = "0400";
      restartUnits = [
        "wg-quick-${interfaceName}.service"
        "game-stream-gateway-policy.service"
      ];
    };

    networking.wg-quick.interfaces.${interfaceName} = {
      autostart = true;
      configFile = configurationFile;
    };

    networking.firewall = {
      allowedUDPPorts = [ cfg.listenPort ];

      # Decrypted packets arrive on wg-game. Refuse gateway-local traffic
      # before the repository's broad RFC1918 accepts can classify it as LAN.
      extraCommands = lib.mkBefore ''
        iptables -w -I nixos-fw 1 -i ${interfaceName} -j nixos-fw-log-refuse
        iptables -w -N ${guardChain} 2>/dev/null || true
        iptables -w -I ${guardChain} 1 -j DROP
        while [ "$(iptables -w -S ${guardChain} | grep -c '^-A ${guardChain} ')" -gt 1 ]; do
          iptables -w -D ${guardChain} 2
        done
        iptables -w -I FORWARD 1 -i ${interfaceName} -j ${guardChain}
        while [ "$(iptables -w -S FORWARD | grep -c '^-A FORWARD -i ${interfaceName} -j ${guardChain}$')" -gt 1 ]; do
          duplicate_line=$(iptables -w -S FORWARD | ${pkgs.gawk}/bin/awk '
            $1 == "-A" { rule_number++ }
            $0 == "-A FORWARD -i ${interfaceName} -j ${guardChain}" { duplicate = rule_number }
            END { print duplicate }
          ')
          iptables -w -D FORWARD "$duplicate_line"
        done
        while iptables -w -C FORWARD -i ${interfaceName} -j ${policyChain} 2>/dev/null; do
          iptables -w -D FORWARD -i ${interfaceName} -j ${policyChain}
        done
        iptables -w -N ${policyChain} 2>/dev/null || true
        iptables -w -F ${policyChain}
        iptables -w -A ${policyChain} -j DROP
        # At initial boot the tunnel is not active yet and the policy service
        # applies later. During reload/restart the live interface is restored
        # here because PartOf does not propagate a systemd reload.
        if ${pkgs.wireguard-tools}/bin/wg show ${interfaceName} >/dev/null 2>&1; then
          ${lib.getExe gatewayControl} apply ${configurationFile} ${interfaceName} ${toString cfg.listenPort}
        fi
      '';
      extraStopCommands = lib.mkAfter ''
        iptables -w -D nixos-fw -i ${interfaceName} -j nixos-fw-log-refuse 2>/dev/null || true
        # Deliberately retain the FORWARD guard after the general firewall is
        # stopped. The WireGuard service has an independent lifecycle, so
        # removing this jump would turn a firewall stop into a tunnel bypass.
        if iptables -w -L ${policyChain} >/dev/null 2>&1; then
          iptables -w -F ${policyChain}
          iptables -w -A ${policyChain} -j DROP
        fi
      '';
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    systemd.services."wg-quick-${interfaceName}".preStart = ''
      ${lib.getExe gatewayControl} validate ${configurationFile} ${interfaceName} ${toString cfg.listenPort}
    '';

    systemd.services.game-stream-gateway-policy = {
      description = "Apply the narrow game-stream WireGuard forwarding policy";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "firewall.service"
        "wg-quick-${interfaceName}.service"
      ];
      after = [
        "firewall.service"
        "wg-quick-${interfaceName}.service"
      ];
      partOf = [
        "firewall.service"
        "wg-quick-${interfaceName}.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe gatewayControl} apply ${configurationFile} ${interfaceName} ${toString cfg.listenPort}";
        ExecStop = "${lib.getExe gatewayControl} remove ${configurationFile} ${interfaceName} ${toString cfg.listenPort}";
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictRealtime = true;
        UMask = "0077";
      };
    };

    environment.systemPackages = [ gatewayControl ];
  };
}
