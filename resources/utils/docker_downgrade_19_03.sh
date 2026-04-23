# Downgrade Docker to 19.3.x to be able to pull docker images with the old format version

sudo apt-get -y remove docker docker-engine docker.io docker-ce containerd runc
sudo rm -rf /var/lib/docker
sudo systemctl stop docker.service 2>/dev/null || true
sudo systemctl stop docker.socket 2>/dev/null || true

# Install prerequisites
sudo apt-get update
sudo apt-get -y install \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  wget

# Create temporary directory for downloads
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "Downloading Docker 19.03.15 packages..."

# Download Docker CE 19.03.15 packages for Ubuntu 16.04 (Xenial)
wget -q https://download.docker.com/linux/ubuntu/dists/xenial/pool/stable/amd64/containerd.io_1.2.13-2_amd64.deb
wget -q https://download.docker.com/linux/ubuntu/dists/xenial/pool/stable/amd64/docker-ce-cli_19.03.15~3-0~ubuntu-xenial_amd64.deb
wget -q https://download.docker.com/linux/ubuntu/dists/xenial/pool/stable/amd64/docker-ce_19.03.15~3-0~ubuntu-xenial_amd64.deb

# Install packages in correct order
echo "Installing containerd.io..."
sudo dpkg -i containerd.io_1.2.13-2_amd64.deb || sudo apt-get install -f -y

echo "Installing docker-ce-cli..."
sudo dpkg -i docker-ce-cli_19.03.15~3-0~ubuntu-*.deb || sudo apt-get install -f -y

echo "Installing docker-ce..."
sudo dpkg -i docker-ce_19.03.15~3-0~ubuntu-*.deb || sudo apt-get install -f -y

# Fix any dependency issues
sudo apt-get install -f -y

# Clean up temporary files
cd /
rm -rf "$TEMP_DIR"

# Hold packages to prevent accidental upgrades
sudo apt-mark hold docker-ce docker-ce-cli containerd.io

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group (optional)
# Get the current username since $USER might not be set in DNANexus
CURRENT_USER=$(whoami)
echo "Adding user $CURRENT_USER to docker group..."
sudo usermod -aG docker $CURRENT_USER

# Test Docker installation
echo "Testing Docker 19.03.x installation:"
client_docker_version=$(sudo docker version | grep -A 1 "Client: Docker Engine - Community" | grep -o "19.03.")
server_docker_version=$(sudo docker version | grep -A 2 "Server: Docker Engine - Community" | grep -o "19.03.")
if [ "${client_docker_version}" == "${server_docker_version}" ]; then
    echo "Client Docker Version and Server Docker Version are the same"
  else
    echo "Client Docker Version and Server Docker Version are not the same - exiting job" >&2
    exit 1
fi

# Configure Docker for legacy image format support
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
 "experimental": true,
 "storage-driver": "overlay2",
 "log-driver": "json-file",
 "log-opts": {
   "max-size": "10m",
   "max-file": "3"
 }
}
EOF

# Restart Docker to apply configuration
sudo systemctl restart docker

# Wait for Docker to start
sleep 5

# Final test
echo "Final Docker version check:"
client_docker_version=$(sudo docker version | grep -A 1 "Client: Docker Engine - Community" | grep -o "19.03.")
server_docker_version=$(sudo docker version | grep -A 2 "Server: Docker Engine - Community" | grep -o "19.03.")
if [ "${client_docker_version}" == "${server_docker_version}" ]; then
    echo "Client Docker Version and Server Docker Version are the same"
  else
    echo "Client Docker Version and Server Docker Version are not the same - exiting job" >&2
    exit 1
fi