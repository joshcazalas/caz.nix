{
  lib,
  pkgs,
  settings,
  ...
}:
let
  inherit (settings.server) lanAddress lanInterface;
  ipset = "${pkgs.ipset}/bin/ipset";
  senderSet = "gateway-syslog-v4";

  # The exporter is the DHCP gateway on the physical server LAN. Populate
  # the set after DHCP, even when the firewall started before the lease.
  selectSender = pkgs.writeShellScript "select-gateway-syslog-sender" ''
    set -eu
    gateway=$(${pkgs.iproute2}/bin/ip -4 route show default dev ${lib.escapeShellArg lanInterface} |
      ${pkgs.gawk}/bin/awk '$1 == "default" && $2 == "via" {print $3; exit}')
    ${ipset} create ${senderSet}-next hash:ip family inet -exist
    ${ipset} flush ${senderSet}-next
    ${ipset} add ${senderSet}-next "$gateway"
    ${ipset} swap ${senderSet}-next ${senderSet}
    ${ipset} destroy ${senderSet}-next
  '';

  flowDirectory = "/var/lib/gateway-flows";

  receiverConfig = pkgs.writeText "gateway-syslog.conf" ''
    module(load="imudp")
    module(load="omstdout")
    template(name="gatewayLine" type="string" string="%rawmsg%")
    input(type="imudp" address="${lanAddress}" port="514")
    if $inputname == "imudp" then action(type="omstdout" template="gatewayLine")
  '';
in
{
  networking.firewall.extraCommands = ''
    ${ipset} create ${senderSet} hash:ip family inet -exist
    iptables -w -A nixos-fw -i ${lib.escapeShellArg lanInterface} -d ${lanAddress}/32 \
      -p udp -m multiport --dports 514,4739 -m set --match-set ${senderSet} src -j nixos-fw-accept
  '';

  environment.systemPackages = [ pkgs.nfdump ];

  systemd.services.gateway-flows = {
    description = "Collect IPFIX records from the LAN gateway";
    wantedBy = [ "multi-user.target" ];
    # The syslog receiver populates the shared gateway-only firewall set.
    wants = [ "gateway-syslog.service" ];
    after = [
      "gateway-syslog.service"
      "network-online.target"
    ];
    environment.TZ = "UTC";
    serviceConfig = {
      DynamicUser = true;
      StateDirectory = "gateway-flows";
      StateDirectoryMode = "0700";
      UMask = "0077";
      ExecStartPre = "${pkgs.nfdump}/bin/nfexpire -u ${flowDirectory} -s 512m -t 14d -w 95";
      ExecStart = "${pkgs.nfdump}/bin/nfcapd -4 -b ${lanAddress} -p 4739 -w ${flowDirectory} -t 300 -e -z=lz4";
      NoNewPrivileges = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  environment.etc."systemd/journald@gateway.conf".text = ''
    [Journal]
    Storage=persistent
    SystemMaxUse=256M
    SystemMaxFileSize=16M
    MaxFileSec=1day
    MaxRetentionSec=30day
    ForwardToSyslog=no
  '';

  systemd.services.gateway-syslog = {
    description = "Receive syslog events from the LAN gateway";
    wantedBy = [ "multi-user.target" ];
    requires = [ "firewall.service" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "firewall.service"
    ];
    serviceConfig = {
      ExecStartPre = "+${selectSender}";
      ExecStart = "${pkgs.rsyslog}/sbin/rsyslogd -n -iNONE -f ${receiverConfig}";
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      LogNamespace = "gateway";
      StandardOutput = "journal";
      ProtectHome = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
