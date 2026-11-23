#!/bin/bash
# nat-up.sh: временный NAT Gateway для приватной подсети (EIP -> NAT -> маршрут).
# Идентификаторы пишет в scripts/.nat-ids, их читает nat-down.sh. Запуск: CloudShell или Git Bash / обычный bash.
set -euo pipefail

AWS_REGION=eu-central-1
PUBLIC_SUBNET=subnet-0729479be1bfdc8d6   # timecapsule-dev-public-a
PRIVATE_RT=rtb-0ddf838897b87f96f         # timecapsule-dev-private-rt
IDS="$(dirname "$0")/.nat-ids"
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION

tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=timecapsule},{Key=Environment,Value=dev},{Key=Owner,Value=ivanbordeniuc},{Key=Lab,Value=lab3},{Key=Team,Value=solo},{Key=Stack,Value=php}]"; }

[ -f "$IDS" ] && { echo "$IDS уже есть: NAT уже поднят? Сначала nat-down.sh" >&2; exit 1; }

echo "[1/5] allocate-address"
ALLOC=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip timecapsule-dev-nat-a-eip)" --query AllocationId --output text)
echo "ALLOC=$ALLOC" > "$IDS"            # сразу пишем, чтобы адрес не потерялся, если дальше упадёт

echo "[2/5] create-nat-gateway ($PUBLIC_SUBNET)"
NAT=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET" --allocation-id "$ALLOC" --connectivity-type public \
  --tag-specifications "$(tags natgateway timecapsule-dev-nat-a)" --query NatGateway.NatGatewayId --output text)
echo "NAT=$NAT" >> "$IDS"

echo "[3/5] wait nat-gateway-available (пара минут)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"

echo "[4/5] route 0.0.0.0/0 -> $NAT"
# после ручной части в консоли в таблице может висеть Blackhole-маршрут: тогда не create, а replace
aws ec2 create-route --route-table-id "$PRIVATE_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT" >/dev/null \
  || aws ec2 replace-route --route-table-id "$PRIVATE_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"

echo "[5/5] ids -> $IDS"
cat "$IDS"
echo "NAT готов. Не забудь nat-down.sh: шлюз стоит денег каждый час."
