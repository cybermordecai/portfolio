#!/bin/sh

### ReadMe
#
# Скрипт для созданий рабочих нод на docker swarm на centos 7
# 
# Устанавливает docker и containerd, логинится в локальный репозиторий, отключает firewalld и selinux,
# устанавливает связку cadvisor и node-exporter, устанавливает плагин loki для сбора логов, устанавливаем
# portainer
#
# Переменными задается большая часть используемых версий, логинов и паролей, сетевые адреса а так же что 
# устанавливать и использовать. Версиии grafana, плагина loki, cadvisor и node-exporter заданы жестко, 
# искать и менять уже в самом скрипте
#
# cadvisor доступен по порту 9080, node-exporter по порту 9100, portainer на порт 9000
#
###


### Заполняем переменные! ###

# Важно! Эту переменную нужно указать точно
VARLOCALIP=192.168.0.100                # Локальный IP-сервера

# Остальное
VARDOCKERVER=19.03.6                    # Версия docker
VARCONTAINERDVER=1.2.6                  # Версия containerd.io
VARREGISTRYPATH=registry.example.site   # Локальное реджестри
VARREGESTRYUSER=username                # Пользователь реджестри
VARREGESTRYPASS=password                # Пароль реджестри
VARSELINUX=1                            # Отключение SELinux, если 1, то отключаем, если иное, то не трогаем
VARFIREWALLD=1                          # Отключение Firewalld, если 1, то отключаем, если иное, то не трогаем
VARPORTAINER=1                          # Установка Portainer, если 1, то устанавливаем, если иное, то не трогаем
VARMONITORING=1                         # Установка мониторинга, если 1, то устанавливаем, если иное, то не трогаем


### Поехали! ###

# Отключаем SELinux. Или нет
if [ "$VARSELINUX" -eq "1" ]
then
  setenforce 0
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  echo "Step A - SELinux disable!"
else
  echo "Step A - Do not touch the SELinux!"
fi

# Отключаем Firewalld. Или нет
if [ "$VARFIREWALLD" -eq "1" ]
then
  systemctl stop firewalld
  systemctl disable firewalld
  echo "Step B - Firewalld disable!"
else
  echo "Step B - Do not touch the Firewalld!"
fi

# Ставим пакеты утилит, добавляем репозиторий docker и устанавливаем его
echo "Step 1 - Install utils, docker.repo and docker package"
yum install -y yum-utils device-mapper-persistent-data lvm2
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce-$VARDOCKERVER docker-ce-cli-$VARDOCKERVER containerd.io-$VARCONTAINERDVER

# Делаем службу для docker
echo "Step 2 - Create and start docker daemon"
mkdir -p /etc/docker/
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF
mkdir -p /etc/systemd/system/docker.service.d

# Запускаем службу
systemctl daemon-reload
systemctl enable --now docker
systemctl start docker

# Блочим апдейт пакетов докера
echo "Step 3 - Block docker version"
yum install -y yum-versionlock
yum versionlock docker-ce-$VARDOCKERVER docker-ce-cli-$VARDOCKERVER containerd.io-$VARCONTAINERDVER

# Логин в нашу репу
echo "Step 4 - Login in local repository"
docker login $VARREGISTRYPATH -u $VARREGESTRYUSER -p $VARREGESTRYPASS

# Инициализируем swarm
echo "Step 5 - Init Docker Swarm"
docker swarm init --advertise-addr $VARLOCALIP

# Поднимаем мониторинг
cat > /tmp/monitoring.yml <<EOF
version: '3.7'
services:
  cadvisor:
    image: google/cadvisor:v0.32.0
    ports:
    - 9080:8080
    volumes:
    - /:/rootfs:ro
    - /var/run:/var/run:rw
    - /sys:/sys:ro
    - /var/lib/docker/:/var/lib/docker:ro
    deploy:
      replicas: 1
      update_config:
        order: start-first
  nodeexporter:
    image: prom/node-exporter:v0.18.1
    ports:
      - 9100:9100
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)'
    deploy:
      replicas: 1
      update_config:
        order: start-first
EOF

if [ "$VARMONITORING" -eq "1" ]
then
  echo "Step 6 - cadvisor and node-exporter deploy"
  docker stack deploy --with-registry-auth --compose-file=/tmp/monitoring.yml metrics
  # Установка плагила Loki
  echo "Step 7 - Loki plugin initial"
  docker plugin install  grafana/loki-docker-driver:master-8db2d06 --alias loki --grant-all-permissions
else
  echo "Step 6 and 7 - Do not install monitoring!"
fi

# Отключаем Firewalld. Или нет
if [ "$VARPORTAINER" -eq "1" ]
then
  curl -L https://downloads.portainer.io/portainer-agent-stack.yml -o portainer-agent-stack.yml
  docker stack deploy --compose-file=portainer-agent-stack.yml portainer
  echo "Step C - Install Portainer!"
else
  echo "Step B - Do not install Portainer!"
fi

echo "!!! FIHISH !!!"
# Закончили