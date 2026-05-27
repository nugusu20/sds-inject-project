Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  config.vm.define "sds-control" do |node|
    node.vm.hostname = "sds-control"
    node.vm.network "private_network", ip: "192.168.56.120"

    node.vm.provider "virtualbox" do |vb|
      vb.name = "sds-control"
      vb.cpus = 2
      vb.memory = 3072
    end

    node.vm.provision "shell", privileged: true, inline: <<-SHELL
      hostnamectl set-hostname sds-control
      sed -i '/[[:space:]]sds-control/d; /[[:space:]]sds-worker/d' /etc/hosts
      echo "192.168.56.120 sds-control" >> /etc/hosts
      echo "192.168.56.121 sds-worker" >> /etc/hosts
    SHELL
  end

  config.vm.define "sds-worker" do |node|
    node.vm.hostname = "sds-worker"
    node.vm.network "private_network", ip: "192.168.56.121"

    node.vm.provider "virtualbox" do |vb|
      vb.name = "sds-worker"
      vb.cpus = 2
      vb.memory = 3072
    end

    node.vm.provision "shell", privileged: true, inline: <<-SHELL
      hostnamectl set-hostname sds-worker
      sed -i '/[[:space:]]sds-control/d; /[[:space:]]sds-worker/d' /etc/hosts
      echo "192.168.56.120 sds-control" >> /etc/hosts
      echo "192.168.56.121 sds-worker" >> /etc/hosts
    SHELL
  end
end
