#!/usr/bin/env bash
# Lista buckets donde Block Public Access NO está totalmente activado

for bucket in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  result=$(aws s3api get-public-access-block --bucket "$bucket" 2>&1) || true

  if echo "$result" | grep -q "NoSuchPublicAccessBlockConfiguration"; then
    echo "SIN BPA: $bucket (sin configuración)"
    continue
  fi

  # Si falla por permisos u otro error
  if echo "$result" | grep -qi "error\|AccessDenied\|Unauthorized"; then
    echo "ERROR/SIN PERMISO: $bucket"
    continue
  fi

  # Comprueba que los 4 estén en true
  all_true=$(echo "$result" | jq -r '
    .PublicAccessBlockConfiguration as $c
    | ($c.BlockPublicAcls and $c.IgnorePublicAcls and $c.BlockPublicPolicy and $c.RestrictPublicBuckets)
  ')

  if [ "$all_true" = "true" ]; then
    echo "BPA ACTIVO: $bucket"
  else
    echo "BPA INCOMPLETO: $bucket"
    echo "$result" | jq '.PublicAccessBlockConfiguration'
fi
done