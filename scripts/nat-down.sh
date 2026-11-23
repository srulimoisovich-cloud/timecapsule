#!/bin/bash
# nat-down.sh: убрать временный NAT: маршрут, шлюз, потом Elastic IP (читает scripts/.nat-ids).
set -euo pipefail

AWS_REGION=eu-central-1
PRIVATE_RT=rtb-0ddf838897b87f96f         # timecapsule-dev-private-rt
IDS="$(dirname "$0")/.nat-ids"
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION

[ -f "$IDS" ] || { echo "нет $IDS: nat-up.sh не запускали" >&2; exit 1; }
# shellcheck disable=SC1090
. "$IDS"
: "${NAT:?в $IDS нет NAT}" "${ALLOC:?в $IDS нет ALLOC}"

echo "[1/4] delete-route 0.0.0.0/0"
aws ec2 delete-route --route-table-id "$PRIVATE_RT" --destination-cidr-block 0.0.0.0/0

echo "[2/4] delete-nat-gateway $NAT"
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" >/dev/null

echo "[3/4] wait nat-gateway-deleted"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT"

# EIP отпускается только после удаления шлюза, пока он привязан, release-address отвечает ошибкой.
# Сразу после Deleted адрес бывает ещё занят, поэтому до 6 попыток с паузой 10 с.
echo "[4/4] release-address $ALLOC"
for i in 1 2 3 4 5 6; do
  if aws ec2 release-address --allocation-id "$ALLOC"; then
    rm -f "$IDS"
    echo "NAT и Elastic IP удалены."
    exit 0
  fi
  echo "  попытка $i не вышла, жду 10 с"
  sleep 10
done
echo "Elastic IP $ALLOC не освободился. Освободить руками: aws ec2 release-address --allocation-id $ALLOC" >&2
exit 1
