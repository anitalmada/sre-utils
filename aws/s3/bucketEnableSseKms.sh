#!/usr/bin/env bash
# Aplica cifrado por defecto SSE-KMS a buckets que no lo tienen.
# Por defecto corre en DRY-RUN (no modifica nada): muestra dónde impactaría.
#
# Excluye buckets cuyo nombre termina en "-public" (patrón *-public).
# Motivo: SSE-KMS exige SigV4; URLs públicas anónimas de la app fallan.
#
# Uso:
#   ./bucketEnableSseKms.sh                  # dry-run: plan de impacto
#   ./bucketEnableSseKms.sh --apply          # aplica con clave AWS managed aws/s3
#   ./bucketEnableSseKms.sh --apply --cmk alias/mi-clave-s3
#   ./bucketEnableSseKms.sh --apply --cmk arn:aws:kms:REGION:ACCOUNT:key/KEY-ID
#
# No re-cifra objetos existentes: solo cambia el default del bucket (objetos nuevos).

set -euo pipefail

APPLY=0
CMK=""
BUCKET_KEY=true

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --cmk) CMK="${2:-}"; shift 2 ;;
    --no-bucket-key) BUCKET_KEY=false; shift ;;
    -h|--help) usage ;;
    *) echo "Flag desconocido: $1"; usage ;;
  esac
done

if [[ -n "$CMK" ]]; then
  KEY_SPEC="\"KMSMasterKeyID\": \"$CMK\","
  KEY_LABEL="$CMK"
else
  # Sin KMSMasterKeyID => AWS usa/crea la managed key aws/s3 en la región
  KEY_SPEC=""
  KEY_LABEL="aws/s3 (AWS managed, se usa/crea sola al aplicar)"
fi

echo "=== Bulk SSE-KMS (default encryption) ==="
echo "Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Modo: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo "Clave: $KEY_LABEL"
echo "BucketKeyEnabled: $BUCKET_KEY"
echo "Excluidos: nombres que coinciden con *-public"
echo "Nota: objetos ya alojados NO se re-cifran; solo afecta uploads nuevos."
echo

planned=0
skipped_ok=0
excluded_public=0
applied=0
failed=0

ENCRYPTION_JSON=$(cat <<EOF
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        ${KEY_SPEC}
        "SSEAlgorithm": "aws:kms"
      },
      "BucketKeyEnabled": ${BUCKET_KEY}
    }
  ]
}
EOF
)

for bucket in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  # Buckets públicos de la plataforma (URLs anónimas): SSE-KMS rompe el acceso
  if [[ "$bucket" == *-public ]]; then
    echo "EXCLUIDO (*-public): $bucket"
    echo "  Motivo: acceso anónimo incompatible con SSE-KMS (requiere SigV4)"
    excluded_public=$((excluded_public + 1))
    echo
    continue
  fi

  result=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>&1) || true

  if echo "$result" | grep -q "ServerSideEncryptionConfigurationNotFoundError"; then
    current="SIN DEFAULT"
  elif echo "$result" | grep -qi "AccessDenied\|Unauthorized\|NoSuchBucket\|error"; then
    echo "SKIP ERROR: $bucket — no se pudo leer encryption"
    echo "  $(echo "$result" | tr '\n' ' ' | head -c 180)"
    failed=$((failed + 1))
    echo
    continue
  else
    algo=$(echo "$result" | jq -r '
      .ServerSideEncryptionConfiguration.Rules[0]
      .ApplyServerSideEncryptionByDefault.SSEAlgorithm // "NONE"
    ' 2>/dev/null || echo "NONE")
    key=$(echo "$result" | jq -r '
      .ServerSideEncryptionConfiguration.Rules[0]
      .ApplyServerSideEncryptionByDefault.KMSMasterKeyID // ""
    ' 2>/dev/null || echo "")

    if [[ "$algo" == "aws:kms" ]]; then
      echo "OK (ya SSE-KMS): $bucket"
      echo "  Key: ${key:-aws/s3}"
      skipped_ok=$((skipped_ok + 1))
      echo
      continue
    fi

    current="SSEAlgorithm=$algo"
  fi

  planned=$((planned + 1))
  echo "PLAN: $bucket ($current -> aws:kms / $KEY_LABEL)"

  if [[ $APPLY -eq 0 ]]; then
    echo "  (dry-run) no se aplicó — candidato a cambio"
    echo
    continue
  fi

  if aws s3api put-bucket-encryption \
      --bucket "$bucket" \
      --server-side-encryption-configuration "$ENCRYPTION_JSON" 2> /tmp/sse-kms-err.$$; then
    echo "  APLICADO"
    applied=$((applied + 1))
  else
    echo "  FALLO al aplicar:"
    sed 's/^/  /' /tmp/sse-kms-err.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/sse-kms-err.$$
  echo
done

echo "=== Resumen ==="
echo "Excluidos (*-public): $excluded_public"
echo "Ya OK (SSE-KMS):     $skipped_ok"
echo "Candidatos a cambio: $planned"
if [[ $APPLY -eq 1 ]]; then
  echo "Aplicados:           $applied"
  echo "Fallidos:            $failed"
else
  echo "Aplicados:           0 (dry-run). Revisá los PLAN arriba; --apply para cambiar."
  echo "Fallidos lectura:    $failed"
fi
echo
echo "Impacto en datos existentes: ninguno (no se reescriben objetos)."
echo "Buckets *-public quedan fuera a propósito (URLs públicas / SigV4)."
