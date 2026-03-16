# code: language=ruby

Vagrant.configure("2") do |config|
  # Specify the base box to use, in this case an Arch Linux box
  config.vm.box = "generic/arch"

  # Define configurations for multiple virtual machines with their specific settings
  server = {
    "swarm01" => {
      ip: "192.168.34.11",
      memory: 4096,
      cpus: 4,
      groups: { "swarm_managers" => ["swarm01"] }
    },
    "swarm02" => {
      ip: "192.168.34.12",
      memory: 2048,
      cpus: 2,
      groups: { "swarm_workers" => ["swarm02"] }
    },
    "swarm03" => {
      ip: "192.168.34.13",
      memory: 2048,
      cpus: 2,
      groups: { "swarm_workers" => ["swarm03"] }
    }
  }

  # Initialize a hash to store all group configurations for Ansible
  all_groups = {}
  # Determine which machines are specified as command line arguments
  running_machines = ARGV.select { |arg| server.keys.include?(arg) }
  provision_done = false  # Variable to track if provisioning is done

  # Iterate over each machine configuration and define it in Vagrant
  server.each do |name, config_params|
    config.vm.define name do |node|
      # Configure network settings and hostname for the VM
      node.vm.network "private_network", ip: config_params[:ip]
      # synced_folder with virtiofs requires memory_backing_dir = "/dev/shm" in /etc/libvirt/qemu.conf
      node.vm.synced_folder "./shared", "/vagrant", type: "virtiofs"
      node.vm.hostname = name

      # Use Libvirt provider to specify CPU, memory, and other settings
      node.vm.provider :libvirt do |libvirt|
        libvirt.cpus = config_params[:cpus]
        libvirt.memory = config_params[:memory]
        libvirt.memorybacking :access, :mode => "shared"
        libvirt.cputopology :sockets => '1', :cores => config_params[:cpus].to_s, :threads => '1'
      end

      # Collect group configurations for Ansible provisioning
      config_params[:groups].each do |group, hosts|
        all_groups[group] ||= []
        all_groups[group].concat(hosts)
      end

      # Determine whether to provision all VMs or specific ones based on arguments
      provision_all = running_machines.empty?
      provision_single = !running_machines.empty? && running_machines.include?(name)

      # Mount repo root on manager for local GitOps testing
      if name == "swarm01"
        node.vm.synced_folder ".", "/repo", type: "virtiofs"
      end

      # Install Python on each VM individually
      node.vm.provision "python-install", type: "shell", inline: <<-SHELL
        pacman -Sy --noconfirm archlinux-keyring
        pacman -Sy --noconfirm python openssl git fakeroot debugedit
        pacman -Syu --noconfirm --ignore linux,linux-headers
      SHELL

      # Set up local git server on manager for testing without GitHub push
      if name == "swarm01"
        node.vm.provision "git-server", type: "shell", inline: <<-SHELL
          # Create bare repo from mounted source
          mkdir -p /srv/git
          if [ ! -d /srv/git/swarm-git-ops.git ]; then
            git clone --bare /repo /srv/git/swarm-git-ops.git
          fi
          chown -R vagrant:vagrant /srv/git

          # Create systemd unit for git daemon
          cat > /etc/systemd/system/git-daemon.service << 'UNIT'
[Unit]
Description=Git Daemon for local SwarmCD testing
After=network.target

[Service]
ExecStart=/usr/bin/git daemon --reuseaddr --base-path=/srv/git --export-all /srv/git
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

          systemctl daemon-reload
          systemctl enable --now git-daemon
        SHELL
      end

      # Configure Ansible provisioner (only once for all VMs)
      if (provision_all && !provision_done) || provision_single
        node.vm.provision :ansible do |ansible|
          ansible.limit = "all"
          ansible.compatibility_mode = "2.0"
          ansible.config_file = "ansible/ansible.cfg"
          ansible.playbook = "ansible/install.yaml"
          ansible.extra_vars = "@ansible/inventory/vagrant/group_vars/all/main.yaml"
          ansible.galaxy_role_file = "ansible/requirements.yaml"
          ansible.groups = all_groups
          ansible.become = true
          #ansible.raw_arguments = ['-vvv']
          ansible.verbose = true
        end
        provision_done = true  # Set the flag to true after provisioning the first time
      end
    end
  end
end
