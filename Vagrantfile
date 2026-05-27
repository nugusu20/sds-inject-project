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
  end

  config.vm.define "sds-worker" do |node|
    node.vm.hostname = "sds-worker"
    node.vm.network "private_network", ip: "192.168.56.121"

    node.vm.provider "virtualbox" do |vb|
      vb.name = "sds-worker"
      vb.cpus = 2
      vb.memory = 3072
    end
  end
end
