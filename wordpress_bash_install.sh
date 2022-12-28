#!/usr/bin/env bash
# v1.1.0
# Author: @Keylies

set -Eeuo pipefail

msg() {
  echo >&2 -e "${1-}"
}

if [ "$EUID" -ne 0 ]
then 
  echo "Please run this script as root ('su' to change user)"
  exit
fi

dbPwd=
copyExistingWp=
wpToCopyPath=
wpName=
wpAdminName=
wpAdminEmail=
wpAdminPwd=
wpNumberStart=
wpNumberEnd=
isNumber='^[0-9]+$'
isEmail="^(([A-Za-z0-9]+((\.|\-|\_|\+)?[A-Za-z0-9]?)*[A-Za-z0-9]+)|[A-Za-z0-9]+)@(([A-Za-z0-9]+)+((\.|\-|\_)?([A-Za-z0-9]+)+)*)+\.([A-Za-z]{2,})+$"
ip4=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

msg "========== Necessary information =========="
read -s -p "Database password: " dbPwd
read -p $'\nMake a copy of an already installed WordPress (y/n) ? ' copyExistingWp

if  [ "$copyExistingWp" = "Y" ] || [ "$copyExistingWp" = "y" ] 
then
  while [ -z "$wpToCopyPath" ] 
  do
    read -p "The WordPress path to copy  (eg. /var/www/html/wordpress): " wpToCopyPath

    if  [ -z "$wpToCopyPath" ] 
    then
      msg "The path is required, please try again"
    fi
  done
else
  while [ -z "$wpAdminName" ] 
  do
    read -p "The name of the admin user to create on the WordPress: " wpAdminName
    if  [ -z "$wpAdminName" ] 
    then
      msg "Name is required, please try again"
    fi
  done

  while [ -z "$wpAdminEmail" ] || ! [[ $wpAdminEmail =~ $isEmail ]]
  do
    read -p "The email of the admin user: " wpAdminEmail
    if  [ -z "$wpAdminEmail" ] || ! [[ $wpAdminEmail =~ $isEmail ]]
    then
      msg "An email with the correct format is required, please try again"
    fi
  done

  while [ -z "$wpAdminPwd" ] 
  do
    read -p "The password of the user admin: " wpAdminPwd
    if  [ -z "$wpAdminPwd" ] 
    then
      msg "Password is required, please try again"
    fi
  done
fi

while [ -z "$wpName" ] 
do
  read -p "The name of the WordPress to create, it will be used as a folder name on the server and as the name of the site (eg. wordpress): " wpName
  if  [ -z "$wpName" ] 
  then
    msg "Name is required, please try again"
  fi
done

while [ -z "$wpNumberStart" ] || ! [[ $wpNumberStart =~ $isNumber ]]
do
  read -p "The starting number of the counter (10 for the first WordPress created is wordpress10 for example): " wpNumberStart
  if  [ -z "$wpNumberStart" ] || ! [[ $wpNumberStart =~ $isNumber ]]
  then
    msg "A number is required, please try again"
  fi
done

while [ -z "$wpNumberEnd" ] || ! [[ $wpNumberEnd =~ $isNumber ]] || [ "$wpNumberStart" -gt "$wpNumberEnd" ]
do
  read -p "The end number of the counter (100 for the last WordPress created is wordpress100 for example): " wpNumberEnd
  if  [ -z "$wpNumberEnd" ] || ! [[ $wpNumberEnd =~ $isNumber ]]
  then
    msg "A number is required, please try again"
  else
    if  [ "$wpNumberStart" -gt "$wpNumberEnd" ]
    then
      msg "The number must be greater than the start of the counter, please try again"
    fi
  fi
done

msg "----- Move to /tmp folder"
cd /tmp

msg ""
msg "========== Installation/upgrade of WP CLI =========="
result=$(curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar)
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
wp --info

if ! dpkg -l phpmyadmin | grep -q ^ii; then
  msg ""
  msg "========== Installation of phpmyadmin =========="
  debconf-set-selections <<<'phpmyadmin phpmyadmin/dbconfig-install boolean false'
  debconf-set-selections <<<'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2'
  apt install -yq phpmyadmin

    msg ""
    msg "----- Creating the apache configuration"
    touch /etc/apache2/sites-available/phpmyadmin.conf
  cat << EOF > /etc/apache2/sites-available/phpmyadmin.conf
<Directory /var/www/html/phpmyadmin/>
  AllowOverride All
</Directory>
EOF
  a2ensite phpmyadmin
fi

msg ""
msg "========== Installation/update of the usual PHP packages =========="
apt install -y php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip unrar

if ! [ "$copyExistingWp" = "Y" ] && ! [ "$copyExistingWp" = "y" ] 
then
  wpToCopyPath="/var/www/html/$wpName"

  msg ""
  msg "========== Creating a base WordPress instance =========="
  msg "----- Downloading WordPress"
  wp core download --path=$wpToCopyPath --skip-content --allow-root --force
  mkdir -p $wpToCopyPath/wp-content/upgrade;
  mkdir -p $wpToCopyPath/wp-content/themes;
  mkdir -p $wpToCopyPath/wp-content/plugins;

  msg ""
  msg "----- Setting up the config (wp-config.php)"
  wp config create --allow-root --force --path=$wpToCopyPath --dbname=$wpName --dbuser=root --dbpass=$dbPwd

  msg ""
  msg "----- Creation of the database"
  wp db create --allow-root --path=$wpToCopyPath

  msg ""
  msg "----- Installation"
  wp core install --allow-root --path=$wpToCopyPath --url="http://$ip4/$wpName" --title=$wpName --admin_user=$wpAdminName --admin_password=$wpAdminPwd --admin_email="$wpAdminEmail"

  msg ""
  msg "----- Deleting default pages and posts"
  wp post delete $(wp post list --post_type=page,post --format=ids --allow-root --path=$wpToCopyPath) --allow-root --path=$wpToCopyPath --force

  msg ""
  msg "----- Permalink structure set to 'Publication title' mode "
  wp rewrite structure "/%postname%/" --allow-root --hard --path=$wpToCopyPath
  wp rewrite flush --allow-root --hard --path=$wpToCopyPath

  msg ""
  msg "----- Installing the theme"
  wp theme install astra --allow-root --activate --path=$wpToCopyPath

  msg ""
  msg "----- Installation of plugins"
  wp plugin install wp-all-import woocommerce --allow-root --activate --path=$wpToCopyPath

  msg ""
  msg "----- Passing file ownership to the apache user (www-data)"
  chown -R www-data:www-data $wpToCopyPath;

  msg ""
  msg "----- Creating the apache configuration"
  touch /etc/apache2/sites-available/$wpName.conf
  cat << EOF > /etc/apache2/sites-available/$wpName.conf
<Directory /var/www/html/$wpName/>
  AllowOverride All
</Directory>
EOF
  a2ensite $wpName
  a2enmod rewrite
fi

wpToCopyName=$(basename $wpToCopyPath)
wp db export "$wpToCopyName.sql" --allow-root --path=$wpToCopyPath

msg ""
msg "========== Copy of the WordPress =========="
for (( c=$wpNumberStart; c<=$wpNumberEnd; c++ ))
do 
  wpDestPath=/var/www/html/$wpName$c

  msg ""
  msg "----- Copy files from $wpToCopyPath to $wpDestPath"
  rsync -a --info=progress2 $wpToCopyPath/* $wpDestPath --exclude themes --exclude plugins

  msg ""
  msg "----- Creation of symbolic links"
  ln -s $wpToCopyPath/wp-content/plugins/ $wpDestPath/wp-content/;
  ln -s $wpToCopyPath/wp-content/themes/ $wpDestPath/wp-content/;

  msg ""
  msg "----- Passing file ownership to the apache user (www-data)"
  chown -R www-data:www-data $wpDestPath

  msg ""
  msg "----- Update of the configuration (wp-config.php)"
  sed -i "s/$wpToCopyName/$wpName$c/g" $wpDestPath/wp-config.php;
  
  msg ""
  msg "----- Creating the apache configuration"
  cp /etc/apache2/sites-available/$wpToCopyName.conf /etc/apache2/sites-available/$wpName$c.conf;
  sed -i "s/$wpToCopyName/$wpName$c/g" /etc/apache2/sites-available/$wpName$c.conf;
  a2ensite $wpName$c

  msg ""
  msg "----- Creation and copy of the database"
  mysql -u root --password=$dbPwd -e "CREATE DATABASE $wpName$c CHARACTER SET utf8"
  wp db import "$wpToCopyName.sql" --allow-root --path=$wpDestPath
  wp db query "UPDATE wp_options SET option_value = 'http://$ip4/$wpName$c/' WHERE option_id = 1 OR option_id = 2" --allow-root --path=$wpDestPath
done

msg ""
msg "----- Restarting apache"
/etc/init.d/apache2 restart
rm "$wpToCopyName.sql"