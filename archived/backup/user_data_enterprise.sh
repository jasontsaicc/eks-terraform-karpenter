#!/bin/bash

# 企業級 EKS 節點初始化腳本
# Author: jasontsai
# 包含安全強化、監控、和合規配置

set -o xtrace

# 參數
CLUSTER_NAME="${cluster_name}"
B64_CLUSTER_CA="${ca_certificate}"
API_SERVER_URL="${endpoint}"
BOOTSTRAP_ARGUMENTS="${bootstrap_arguments}"

# 企業級安全強化
echo "=== 企業級安全強化 ==="

# 1. 系統更新
yum update -y
yum upgrade -y

# 2. 安裝必要的安全工具
yum install -y \
    amazon-cloudwatch-agent \
    amazon-ssm-agent \
    awslogs \
    htop \
    iotop \
    netstat-nat \
    tcpdump \
    strace \
    lsof

# 3. 配置時間同步（合規要求）
echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd

# 4. 配置審計日誌
echo "=== 配置審計日誌 ==="
cat > /etc/audit/rules.d/k8s.rules << 'EOF'
# Kubernetes 相關審計規則
-w /etc/kubernetes/ -p wa -k kubernetes-config
-w /var/lib/kubelet/ -p wa -k kubelet-config
-w /var/lib/docker/ -p wa -k docker-config
-w /etc/docker/ -p wa -k docker-config
-w /usr/bin/docker -p x -k docker-execution
-w /usr/bin/kubectl -p x -k kubectl-execution
-w /usr/bin/kubelet -p x -k kubelet-execution
EOF

systemctl restart auditd
systemctl enable auditd

# 5. 強化 SSH 配置
echo "=== 強化 SSH 配置 ==="
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
systemctl restart sshd

# 6. 配置防火牆基本規則
echo "=== 配置防火牆 ==="
systemctl enable iptables
systemctl start iptables

# 企業級監控配置
echo "=== 配置企業級監控 ==="

# 1. CloudWatch Agent 配置
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "EKS/Enterprise",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_iowait", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "diskio": {
        "measurement": ["io_time"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "netstat": {
        "measurement": ["tcp_established", "tcp_time_wait"],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/eks/${CLUSTER_NAME}/node/system",
            "log_stream_name": "{instance_id}-system"
          },
          {
            "file_path": "/var/log/secure",
            "log_group_name": "/aws/eks/${CLUSTER_NAME}/node/security",
            "log_stream_name": "{instance_id}-security"
          },
          {
            "file_path": "/var/log/audit/audit.log",
            "log_group_name": "/aws/eks/${CLUSTER_NAME}/node/audit",
            "log_stream_name": "{instance_id}-audit"
          },
          {
            "file_path": "/var/log/pods/**/*.log",
            "log_group_name": "/aws/eks/${CLUSTER_NAME}/node/pods",
            "log_stream_name": "{instance_id}-pods"
          }
        ]
      }
    }
  }
}
EOF

# 啟動 CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# 2. 配置日誌輪轉
cat > /etc/logrotate.d/kubernetes << 'EOF'
/var/log/pods/*.log {
    daily
    missingok
    rotate 30
    compress
    notifempty
    create 644 root root
    postrotate
        /bin/kill -USR1 `cat /run/rsyslog.pid 2> /dev/null` 2> /dev/null || true
    endscript
}
EOF

# 企業級 Kubelet 配置
echo "=== 配置企業級 Kubelet ==="

# 創建 Kubelet 配置目錄
mkdir -p /etc/kubernetes/kubelet

# 企業級 Kubelet 配置
cat > /etc/kubernetes/kubelet/kubelet-config.json << EOF
{
  "kind": "KubeletConfiguration",
  "apiVersion": "kubelet.config.k8s.io/v1beta1",
  "address": "0.0.0.0",
  "port": 10250,
  "readOnlyPort": 0,
  "cgroupDriver": "systemd",
  "hairpinMode": "hairpin-veth",
  "serializeImagePulls": false,
  "featureGates": {
    "RotateKubeletServerCertificate": true
  },
  "protectKernelDefaults": true,
  "clusterDomain": "cluster.local",
  "clusterDNS": ["172.20.0.10"],
  "streamingConnectionIdleTimeout": "30m",
  "nodeStatusUpdateFrequency": "10s",
  "kubeAPIQPS": 10,
  "kubeAPIBurst": 100,
  "evictionHard": {
    "memory.available": "200Mi",
    "nodefs.available": "10%",
    "nodefs.inodesFree": "10%",
    "imagefs.available": "15%"
  },
  "evictionSoft": {
    "memory.available": "500Mi",
    "nodefs.available": "15%",
    "nodefs.inodesFree": "15%",
    "imagefs.available": "20%"
  },
  "evictionSoftGracePeriod": {
    "memory.available": "1m30s",
    "nodefs.available": "1m30s",
    "nodefs.inodesFree": "1m30s",
    "imagefs.available": "1m30s"
  }
}
EOF

# 企業級容器運行時優化
echo "=== 配置容器運行時 ==="

# Containerd 配置優化
mkdir -p /etc/containerd
cat > /etc/containerd/config.toml << 'EOF'
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  address = ""
  uid = 0
  gid = 0
  level = ""

[metrics]
  address = ""
  grpc_histogram = false

[cgroup]
  path = ""

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    disable_tcp_service = true
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    stream_idle_timeout = "4h0m0s"
    enable_selinux = false
    selinux_category_range = 1024
    sandbox_image = "602401143452.dkr.ecr.${AWS::Region}.amazonaws.com/eks/pause:3.5"
    stats_collect_period = 10
    systemd_cgroup = false
    enable_tls_streaming = false
    max_container_log_line_size = 16384
    disable_cgroup = false
    disable_apparmor = false
    restrict_oom_score_adj = false
    max_concurrent_downloads = 3
    disable_proc_mount = false
    unset_seccomp_profile = ""
    tolerate_missing_hugepages_controller = true
    disable_hugetlb_controller = true
    ignore_image_defined_volumes = false
    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      default_runtime_name = "runc"
      no_pivot = false
      disable_snapshot_annotations = true
      discard_unpacked_layers = false
      [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
        runtime_type = ""
        runtime_engine = ""
        runtime_root = ""
        privileged_without_host_devices = false
        base_runtime_spec = ""
      [plugins."io.containerd.grpc.v1.cri".containerd.untrusted_workload_runtime]
        runtime_type = ""
        runtime_engine = ""
        runtime_root = ""
        privileged_without_host_devices = false
        base_runtime_spec = ""
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          privileged_without_host_devices = false
          base_runtime_spec = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
EOF

# 啟動 containerd
systemctl enable containerd
systemctl start containerd

# 企業級網路安全配置
echo "=== 配置網路安全 ==="

# 內核參數優化
cat >> /etc/sysctl.conf << 'EOF'
# 企業級網路安全參數
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 記憶體保護
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# 檔案系統保護
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# 程序保護
kernel.yama.ptrace_scope = 1
EOF

sysctl -p

# 引導 EKS 節點
echo "=== 引導 EKS 節點 ==="
/etc/eks/bootstrap.sh $CLUSTER_NAME $BOOTSTRAP_ARGUMENTS

# 企業級服務監控
echo "=== 配置服務監控 ==="

# 創建健康檢查腳本
cat > /opt/health-check.sh << 'EOF'
#!/bin/bash

LOG_FILE="/var/log/health-check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 檢查關鍵服務
services=("kubelet" "containerd" "amazon-cloudwatch-agent" "amazon-ssm-agent")

for service in "${services[@]}"; do
    if systemctl is-active --quiet $service; then
        echo "[$TIMESTAMP] $service: HEALTHY" >> $LOG_FILE
    else
        echo "[$TIMESTAMP] $service: UNHEALTHY - restarting" >> $LOG_FILE
        systemctl restart $service
    fi
done

# 檢查磁碟空間
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | cut -d'%' -f1)
if [ $DISK_USAGE -gt 85 ]; then
    echo "[$TIMESTAMP] DISK: WARNING - ${DISK_USAGE}% used" >> $LOG_FILE
fi

# 檢查記憶體使用率
MEMORY_USAGE=$(free | awk 'NR==2{printf "%.2f\n", $3*100/$2}')
if (( $(echo "$MEMORY_USAGE > 85" | bc -l) )); then
    echo "[$TIMESTAMP] MEMORY: WARNING - ${MEMORY_USAGE}% used" >> $LOG_FILE
fi
EOF

chmod +x /opt/health-check.sh

# 添加 cron 作業
echo "*/5 * * * * /opt/health-check.sh" | crontab -

# 啟用服務
systemctl enable kubelet
systemctl enable amazon-cloudwatch-agent
systemctl enable amazon-ssm-agent
systemctl enable crond

echo "=== 企業級節點初始化完成 ==="
echo "節點已成功加入集群: $CLUSTER_NAME"
echo "時間戳: $(date)"

# 發送成功通知到 CloudWatch
aws logs put-log-events \
    --log-group-name "/aws/eks/$CLUSTER_NAME/node/bootstrap" \
    --log-stream-name "$(curl -s http://169.254.169.254/latest/meta-data/instance-id)-bootstrap" \
    --log-events "timestamp=$(date +%s000),message=Enterprise node bootstrap completed successfully" \
    2>/dev/null || true