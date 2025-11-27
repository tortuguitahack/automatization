#!/bin/bash
set -e

echo "Actualizando sistema..."
sudo apt update && sudo apt upgrade -y

echo "Instalando dependencias base..."
sudo apt install -y build-essential git curl wget software-properties-common linux-tools-$(uname -r) linux-cloud-tools-$(uname -r)

echo "Instalando drivers NVIDIA y CUDA ToolKit..."
sudo add-apt-repository ppa:graphics-drivers/ppa -y
sudo apt update
sudo ubuntu-drivers autoinstall

sudo apt install -y cuda-toolkit-12-1 libcudnn8 libcudnn8-dev

echo "Configurando variables de entorno CUDA..."
if ! grep -q 'export PATH=/usr/local/cuda-12.1/bin' ~/.bashrc; then
  echo 'export PATH=/usr/local/cuda-12.1/bin:$PATH' >> ~/.bashrc
  echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.1/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
fi
source ~/.bashrc

echo "Instalando Python3 y paquetes para IA..."
sudo apt install -y python3 python3-pip
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip3 install numpy scipy scikit-learn transformers datasets

echo "Configurando CPU governor a performance..."

cat <<EOF | sudo tee /etc/systemd/system/cpu-governor.service
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | tee \$cpu; done'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cpu-governor.service
sudo systemctl start cpu-governor.service

echo "Ajustando parámetros kernel para IA..."

cat <<EOF | sudo tee /etc/sysctl.d/99-ia-optimization.conf
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
net.core.somaxconn=1024
EOF

sudo sysctl --system

echo "Activando persistencia y modo preferente para GPU NVIDIA..."
sudo nvidia-smi -pm 1
sudo nvidia-smi -c 3

echo "Optimización avanzada para cargas IA instalada."
echo "Reinicie el sistema para aplicar todos los cambios."
