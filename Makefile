CURRENT_DIR = $(shell pwd)
CURRENT_IP = $(shell hostname -I | awk '{print $$1}')
HOSTNAME = $(shell hostname)
FQDN = harbor.$(HOSTNAME).com

install-docker:
	sudo apt-get install apt-transport-https ca-certificates curl gnupg lsb-release
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
	echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
	sudo apt-get update
	sudo apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin
	sudo usermod -aG docker $$USER

install-kubectl:
	curl -LO "https://dl.k8s.io/release/$$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
	sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
	kubectl version --client

install-helm:
	curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

install-helmfile:
	curl -Lo ./helmfile.tar.gz https://github.com/helmfile/helmfile/releases/download/v0.162.0/helmfile_0.162.0_linux_amd64.tar.gz
	sudo tar -C /usr/local/bin -xzf helmfile.tar.gz helmfile
	rm -rf ./helmfile.tar.gz

install-nfs:
	@echo $(CURRENT_DIR)
	sudo apt-get install nfs-common nfs-kernel-server -y
	mkdir -p $(CURRENT_DIR)/data
	sudo chmod 2770 $(CURRENT_DIR)/data
	sudo chown nobody:nogroup $(CURRENT_DIR)/data
	echo "$(CURRENT_DIR)/data\t*(rw,sync,no_root_squash,insecure,no_subtree_check,no_auth_nlm,no_all_squash)" | sudo tee -a /etc/exports
	sudo exportfs -av
	sudo systemctl restart nfs-kernel-server

preparation:
	sudo sysctl -w fs.inotify.max_user_watches=2099999999
	sudo sysctl -w fs.inotify.max_user_instances=2099999999
	sudo sysctl -w fs.inotify.max_queued_events=2099999999

harbor-install:
	cd utilities && sudo ./generate-certs.sh --fqdn $(FQDN)
	sudo chmod 2770 $(CURRENT_DIR)/data/cert
	sudo chown nobody:nogroup $(CURRENT_DIR)/data/cert
	mkdir -p $(CURRENT_DIR)/harbor
	curl -Lo ./harbor.tgz https://github.com/goharbor/harbor/releases/download/v2.9.2/harbor-offline-installer-v2.9.2.tgz
	sudo tar -xzf ./harbor.tgz
	rm -rf ./harbor.tgz
	cp ./harbor/harbor.yml.tmpl ./harbor/harbor.yml
	sed -i 's/hostname: reg.mydomain.com/hostname: $(FQDN)/g' ./harbor/harbor.yml
	sed -i 's/certificate: \/your\/certificate\/path/certificate: $(subst /,\/,${CURRENT_DIR})\/data\/cert\/$(FQDN).crt/g' ./harbor/harbor.yml
	sed -i 's/private_key: \/your\/private\/key\/path/private_key: $(subst /,\/,${CURRENT_DIR})\/data\/cert\/$(FQDN).key/g' ./harbor/harbor.yml
	sudo ./harbor/prepare
	sudo ./harbor/install.sh

harbor-up:
	sudo docker compose -f ./harbor/docker-compose.yml up -d

harbor-down:
	sudo docker compose -f ./harbor/docker-compose.yml down

cluster-network:
	curl -Lo cluster/calico.yaml https://projectcalico.docs.tigera.io/manifests/calico.yaml
	sed -i 's/k8s,bgp"/k8s,bgp"\n            - name: IP_AUTODETECTION_METHOD\n              value: "interface=eth.*"/' cluster/calico.yaml
	kubectl apply -f cluster/calico.yaml

cluster-network-delete:
	kubectl delete -f cluster/calico.yaml

cluster-config:
	sed -i 's/server:/server: $(CURRENT_IP)/g' prod/values/nfs.yaml
	sed -i 's|path:|path: $(CURRENT_DIR)/data|g' prod/values/nfs.yaml
	-helmfile sync -e prod -f helmfile.yaml --wait 10m

cluster-config-delete:
	helmfile delete -e prod -f helmfile.yaml

down:
	rm -rf ~/.kube/config
	sed -i 's/server: $(CURRENT_IP)/server:/g' prod/values/nfs.yaml
	sed -i 's|path: $(CURRENT_DIR)/data|path:|g' prod/values/nfs.yaml
	sudo sed -i '\|$(CURRENT_DIR)/data|I d' /etc/exports
	sudo systemctl restart nfs-kernel-server
	sudo rm -rf harbor
	find ./utilities -type f ! -name '*.sh' -delete

apply:
	-helmfile apply -e prod -f helmfile.yaml --wait 10m

up: install-nfs preparation harbor-install

first: install-docker install-kubectl install-helm install-helmfile up