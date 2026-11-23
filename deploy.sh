#!/bin/bash
# deploy.sh: выкатить текущий main на сервер. Запуск: ssh ... ./deploy.sh
set -euo pipefail

cd /var/www/timecapsule

echo "[1/4] git pull"
git pull --ff-only

echo "[2/4] composer"
composer install --no-dev --optimize-autoloader --no-interaction

echo "[3/4] init-db"
php bin/init-db.php

echo "[4/4] reload php-fpm"
sudo systemctl reload php-fpm

# /health смотрит только на PHP и базу, главную страницу не открывает
curl -fsS http://localhost/health && echo
echo "на сервере: $(git log -1 --oneline)"
