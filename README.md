


# VICIDIAL INSTALLATION SCRIPTS (Default is Eastern Time Zone US)
# Centos, Rocky and AlmaLinux Vicidial Install pre_requisites 
# I have created a faster auto installer for Alma and Rocky 9 that will also install the dynamic portal and the CyburPhone

```

hostnamectl set-hostname xxxxxx.xxxxx.xxx
### Use YOUR SubDomain

vi /etc/hosts
##Change domain name for actual server ip (xxx.xxx.xxx.xxx   complete domain name    subdomain only)

timedatectl set-timezone America/New_York

yum check-update
yum update -y
yum -y install epel-release
yum update -y
yum install git -y
yum install -y kernel*

#Disable SELINUX
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config    

cd /usr/src/
git clone https://github.com/carpenox/vicidial-install-scripts.git

reboot

````
  Reboot Before running this script

# Install VICIDIAL scripts

```
cd /usr/src/vicidial-install-scripts
git clone https://github.com/carpenox/vicidial-install-scripts.git
cd vicidial-install-scripts
```

# Alma/Rocky 9 Installer with Dynamic portal, CyburPhone, SSL Cert and Asterisk 11

```
cd /usr/src/vicidial-install-scripts
chmod +x alma-rocky9-ast11.sh
./alma-rocky9-ast11.sh
```

# Alma/Rocky 9 Installer with Dynamic portal, CyburPhone, SSL Cert and Asterisk 16

```
cd /usr/src/vicidial-install-scripts
chmod +x alma-rocky9-ast16.sh
./alma-rocky9-ast16.sh
```

Make sure you update your SSL cert location in /etc/httpd/conf.d/viciportal-ssl.conf

# Alma/Rocky 9 Installer with Dynamic portal and CyburPhone with SSL cert with Asterisk 18

```
cd /usr/src/vicidial-install-scripts
chmod +x alma-rocky9-ast18.sh
./alma-rocky9-ast18.sh
```

Make sure you update your SSL cert location in /etc/httpd/conf.d/viciportal-ssl.conf

# Install a default database with everything setup ready to go

```
cd /usr/src/vicidial-install-scripts
chmod +x standard-db.sh
./standard-db.sh
```


# Alma 8 Add on telephony server for a cluster

```
cd /usr/src/vicidial-install-scripts
chmod +x Vici-alma-dialer-install.sh
./Vici-alma-dialer-install.sh
```

# Execute Centos7 Vicidial Install
```
cd /usr/src/vicidial-install-scripts
chmod +x vicidial-install-c7.sh
./vicidial-install-c7.sh
```

# Execute Alma/Rocky 8 Linux Vicidial Install - Ast 16
```
cd /usr/src/vicidial-install-scripts
chmod +x alma-rocky-centos8-ast16.sh
./alma-rocky-centos8-ast16.sh
```

# Execute Alma/Rocky 8 Linux Vicidial Install - Ast 18
```
cd /usr/src/vicidial-install-scripts
chmod +x alma-rocky-centos-8-ast18.sh
./alma-rocky-centos-8-ast18.sh
```

# Install Webphone and SSL cert for VICIDIAL
# DO THIS IF YOU HAVE PUBLIC DOMAIN WITH PUBLIC IP ONLY

```
cd /usr/src/vicidial-install-scripts
chmod +x vicidial-enable-webrtc.sh
./vicidial-enable-webrtc.sh
```
