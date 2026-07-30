#!/usr/bin/env bash
# Relevamiento: cifrado por defecto de buckets S3 (SSE-KMS vs SSE-S3 vs sin default)
# Salida orientada a justificar remediación (aplicar o no SSE-KMS).

set -euo pipefail

ok_kms=0
ok_kms_aws_managed=0
sse_s3=0
sin_default=0
errores=0

echo "=== Relevamiento cifrado S3 (default encryption) ==="
echo "Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Cuenta/perfil: ${AWS_PROFILE:-default}"
echo "Criterio OK: SSEAlgorithm=aws:kms"
echo

for bucket in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  result=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>&1) || true

  if echo "$result" | grep -q "ServerSideEncryptionConfigurationNotFoundError"; then
    echo "ACCION REQUERIDA | SIN DEFAULT: $bucket"
    echo "  Motivo: no hay ServerSideEncryptionConfiguration"
    echo "  Accion sugerida: put-bucket-encryption con SSEAlgorithm=aws:kms"
    sin_default=$((sin_default + 1))
    echo
    continue
  fi

  if echo "$result" | grep -qi "AccessDenied\|Unauthorized\|NoSuchBucket\|error"; then
    echo "ERROR/SIN PERMISO: $bucket"
    echo "  Detalle: $(echo "$result" | tr '\n' ' ' | head -c 200)"
    errores=$((errores + 1))
    echo
    continue
  fi

  parsed=$(echo "$result" | jq -r '
    .ServerSideEncryptionConfiguration.Rules[0] as $r
    | ($r.ApplyServerSideEncryptionByDefault // {}) as $d
    | [
        ($d.SSEAlgorithm // "NONE"),
        ($d.KMSMasterKeyID // ""),
        (($r.BucketKeyEnabled // false) | tostring)
      ]
    | @tsv
  ' 2>/dev/null) || parsed=""

  if [ -z "$parsed" ]; then
    echo "ERROR PARSEANDO: $bucket"
    errores=$((errores + 1))
    echo
    continue
  fi

  algo=$(echo "$parsed" | cut -f1)
  key_id=$(echo "$parsed" | cut -f2)
  bucket_key=$(echo "$parsed" | cut -f3)

  case "$algo" in
    aws:kms)
      # aws/s3 o ARN/alias de CMK customer-managed
      if [[ "$key_id" == *"/aws/s3" ]] || [[ "$key_id" == "alias/aws/s3" ]] || [[ -z "$key_id" ]]; then
        echo "OK SSE-KMS (aws managed): $bucket"
        echo "  SSEAlgorithm: aws:kms"
        echo "  KMSMasterKeyID: ${key_id:-"(default aws/s3)"}"
        echo "  BucketKeyEnabled: $bucket_key"
        echo "  Accion sugerida: ninguna (cumple SSE-KMS); opcional migrar a CMK propia"
        ok_kms_aws_managed=$((ok_kms_aws_managed + 1))
      else
        echo "OK SSE-KMS (CMK): $bucket"
        echo "  SSEAlgorithm: aws:kms"
        echo "  KMSMasterKeyID: $key_id"
        echo "  BucketKeyEnabled: $bucket_key"
        echo "  Accion sugerida: ninguna"
        ok_kms=$((ok_kms + 1))
      fi
      ;;
    AES256)
      echo "ACCION REQUERIDA | SSE-S3 (AES256): $bucket"
      echo "  SSEAlgorithm: AES256"
      # echo "  Motivo: cifrado por defecto es SSE-S3, no SSE-KMS"
      # echo "  Accion sugerida: cambiar default a aws:kms (+ CMK si aplica)"
      sse_s3=$((sse_s3 + 1))
      ;;
    *)
      echo "ACCION REQUERIDA | DESCONOCIDO: $bucket"
      echo "  SSEAlgorithm: $algo"
      echo "  Accion sugerida: revisar y aplicar aws:kms"
      sin_default=$((sin_default + 1))
      ;;
  esac
  echo
done

echo "=== Resumen (justificacion) ==="
echo "OK SSE-KMS (CMK):           $ok_kms"
echo "OK SSE-KMS (aws/s3):        $ok_kms_aws_managed"
echo "ACCION SSE-S3 (AES256):     $sse_s3"
echo "ACCION sin default:         $sin_default"
echo "Errores / sin permiso:      $errores"
echo
echo "Total a remediar (SSE-KMS): $((sse_s3 + sin_default))"
echo "Nota: este relevamiento cubre default encryption del bucket."
echo "      Objetos ya existentes no se re-cifran solos al cambiar el default."
