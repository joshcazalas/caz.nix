# Hand-written rather than vendored from grafana.com: a small dashboard that
# answers this homeserver's actual questions reviews far better in a pull
# request than a 250 kB third-party JSON blob nobody reads.
let
  datasource = {
    type = "prometheus";
    uid = "homelab-prometheus";
  };

  target = refId: expr: legend: {
    inherit datasource expr refId;
    legendFormat = legend;
    editorMode = "code";
    range = true;
  };

  position = x: y: w: h: {
    inherit
      h
      w
      x
      y
      ;
  };

  stat =
    {
      title,
      expr,
      unit ? "none",
      gridPos,
      thresholds,
      legend ? "",
    }:
    {
      inherit datasource gridPos title;
      type = "stat";
      targets = [ (target "A" expr legend) ];
      options = {
        colorMode = "value";
        graphMode = "area";
        justifyMode = "auto";
        textMode = "auto";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
      fieldConfig = {
        defaults = {
          inherit unit;
          mappings = [ ];
          thresholds = {
            mode = "absolute";
            steps = thresholds;
          };
        };
        overrides = [ ];
      };
    };

  timeseries =
    {
      title,
      targets,
      unit ? "none",
      gridPos,
      min ? null,
      max ? null,
      description ? "",
    }:
    {
      inherit
        datasource
        description
        gridPos
        targets
        title
        ;
      type = "timeseries";
      options = {
        legend = {
          displayMode = "table";
          placement = "bottom";
          showLegend = true;
          calcs = [
            "lastNotNull"
            "max"
          ];
        };
        tooltip.mode = "multi";
      };
      fieldConfig = {
        defaults = {
          inherit unit;
          custom = {
            drawStyle = "line";
            fillOpacity = 8;
            lineWidth = 1;
            showPoints = "never";
          };
        }
        // (if min == null then { } else { inherit min; })
        // (if max == null then { } else { inherit max; });
        overrides = [ ];
      };
    };

  green = {
    color = "green";
    value = null;
  };
in
{
  uid = "homelab-overview";
  title = "Homeserver overview";
  tags = [ "homelab" ];
  timezone = "browser";
  schemaVersion = 39;
  version = 1;
  editable = false;
  refresh = "1m";
  time = {
    from = "now-6h";
    to = "now";
  };

  panels = [
    (stat {
      title = "Failed units";
      expr = ''sum(node_systemd_unit_state{state="failed"}) or vector(0)'';
      gridPos = position 0 0 6 4;
      thresholds = [
        green
        {
          color = "red";
          value = 1;
        }
      ];
    })

    (stat {
      title = "Scrape targets down";
      expr = "sum(up == 0) or vector(0)";
      gridPos = position 6 0 6 4;
      thresholds = [
        green
        {
          color = "red";
          value = 1;
        }
      ];
    })

    (stat {
      title = "Least free filesystem";
      unit = "percent";
      expr = ''
        min(100 * node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|autofs|nsfs|devtmpfs|efivarfs|fuse.*"}
          / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|autofs|nsfs|devtmpfs|efivarfs|fuse.*"})
      '';
      gridPos = position 12 0 6 4;
      thresholds = [
        {
          color = "red";
          value = null;
        }
        {
          color = "orange";
          value = 7;
        }
        {
          color = "green";
          value = 15;
        }
      ];
    })

    (stat {
      title = "Hottest sensor";
      unit = "celsius";
      expr = "max(node_hwmon_temp_celsius)";
      gridPos = position 18 0 6 4;
      thresholds = [
        green
        {
          color = "orange";
          value = 70;
        }
        {
          color = "red";
          value = 80;
        }
      ];
    })

    (timeseries {
      title = "CPU utilisation";
      unit = "percent";
      min = 0;
      max = 100;
      gridPos = position 0 4 12 8;
      targets = [
        (target "A" ''100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))'' "busy")
        (target "B" ''100 * avg(rate(node_cpu_seconds_total{mode="iowait"}[5m]))'' "iowait")
        (target "C" ''100 * avg(rate(node_cpu_seconds_total{mode="steal"}[5m]))'' "steal")
      ];
    })

    (timeseries {
      title = "Memory";
      unit = "bytes";
      min = 0;
      gridPos = position 12 4 12 8;
      targets = [
        (target "A" "node_memory_MemTotal_bytes" "total")
        (target "B" "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes" "used")
        (target "C" "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes" "swap used")
      ];
    })

    (timeseries {
      title = "Filesystem free";
      description = "Real filesystems only. Pseudo-filesystems are excluded the same way the alerting rules exclude them.";
      unit = "percent";
      min = 0;
      max = 100;
      gridPos = position 0 12 12 8;
      targets = [
        (target "A" ''
          100 * node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|autofs|nsfs|devtmpfs|efivarfs|fuse.*"}
            / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|autofs|nsfs|devtmpfs|efivarfs|fuse.*"}
        '' "{{ mountpoint }}")
      ];
    })

    (timeseries {
      title = "Temperatures";
      unit = "celsius";
      gridPos = position 12 12 12 8;
      targets = [
        (target "A" "node_hwmon_temp_celsius" "{{ chip }} {{ sensor }}")
        (target "B" ''smartctl_device_temperature{temperature_type="current"}'' "{{ device }}")
      ];
    })

    (timeseries {
      title = "Disk throughput";
      unit = "Bps";
      gridPos = position 0 20 12 8;
      targets = [
        (target "A" ''rate(node_disk_read_bytes_total{device!~"loop.*|dm-.*"}[5m])'' "{{ device }} read")
        (target "B" ''rate(node_disk_written_bytes_total{device!~"loop.*|dm-.*"}[5m])''
          "{{ device }} write"
        )
      ];
    })

    (timeseries {
      title = "Network throughput";
      unit = "Bps";
      gridPos = position 12 20 12 8;
      targets = [
        (target "A" ''rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m])''
          "{{ device }} in"
        )
        (target "B" ''rate(node_network_transmit_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m])''
          "{{ device }} out"
        )
      ];
    })

    (timeseries {
      title = "Drive endurance and errors";
      description = "Wear and error counters climb slowly. This panel is for noticing trends long before an alert fires.";
      gridPos = position 0 28 24 8;
      targets = [
        (target "A" "smartctl_device_percentage_used" "{{ device }} endurance used %")
        (target "B" "smartctl_device_media_errors" "{{ device }} media errors")
        (target "C" ''
          smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"}
        '' "{{ device }} reallocated sectors")
      ];
    })
  ];
}
