vi#!/bin/bash

# Function to remove existing PHP packages
remove_php() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "opensuse-leap" ]]; then
            sudo zypper remove -y 'php*'
        elif [[ "$ID" == "almalinux" ]]; then
            sudo dnf remove -y 'php*'
        else
            echo "Unsupported distribution"
            exit 1
        fi
    else
        echo "Cannot determine the operating system"
        exit 1
    fi
}

# Function to install PHP 8.2
install_php82() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "opensuse-leap" ]]; then
            sudo zypper addrepo https://download.opensuse.org/repositories/devel:languages:php/openSUSE_Leap_15.6/devel:languages:php.repo
            sudo zypper refresh
            sudo zypper install -y php8 php8-cli php8-fpm php8-mysql php8-zip php8-gd php8-mbstring php8-curl php8-xml php8-bcmath php8-json
        elif [[ "$ID" == "almalinux" ]]; then
            sudo dnf install -y epel-release
            sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
            sudo dnf module reset php -y
            sudo dnf module enable php:remi-8.2 -y
            sudo dnf install -y php php-cli php-fpm php-mysqlnd php-zip php-gd php-mbstring php-curl php-xml php-bcmath php-json
        else
            echo "Unsupported distribution"
            exit 1
        fi
    else
        echo "Cannot determine the operating system"
        exit 1
    fi
}

# Function to install PHP 7.4
install_php74() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "opensuse-leap" ]]; then
            sudo zypper addrepo https://download.opensuse.org/repositories/devel:languages:php/openSUSE_Leap_15.6/devel:languages:php.repo
            sudo zypper refresh
            sudo zypper install -y php7 php7-cli php7-fpm php7-mysql php7-zip php7-gd php7-mbstring php7-curl php7-xml php7-bcmath php7-json
        elif [[ "$ID" == "almalinux" ]]; then
            sudo dnf install -y epel-release
            sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
            sudo dnf module reset php -y
            sudo dnf module enable php:remi-7.4 -y
            sudo dnf install -y php php-cli php-fpm php-mysqlnd php-zip php-gd php-mbstring php-curl php-xml php-bcmath php-json
        else
            echo "Unsupported distribution"
            exit 1
        fi
    else
        echo "Cannot determine the operating system"
        exit 1
    fi
}

# Ask the user for the desired PHP version
echo "Choose the PHP version to install:"
echo "1) PHP 8.2"
echo "2) PHP 7.4"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        remove_php
        install_php82
        ;;
    2)
        remove_php
        install_php74
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac
service httpd restart
service apache2 restart
echo "PHP installation completed."
