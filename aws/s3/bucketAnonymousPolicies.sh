#!/usr/bin/env bash
# Relevamiento: buckets con política que permite acceso anónimo (Principal "*")
# Excluye buckets intencionalmente públicos: *-public-*

set -euo pipefail

for bucket in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  # Buckets de la plataforma con URL públicas: fuera del relevamiento
  if [[ "$bucket" == *-public-* ]]; then
    echo "EXCLUIDO (public): $bucket"
    continue
  fi

  result=$(aws s3api get-bucket-policy --bucket "$bucket" --output text 2>&1) || true

  if echo "$result" | grep -q "NoSuchBucketPolicy"; then
    echo "SIN POLITICA: $bucket"
    continue
  fi

  if echo "$result" | grep -qi "AccessDenied\|Unauthorized\|error"; then
    echo "ERROR/SIN PERMISO: $bucket"
    continue
  fi

  # Analiza si hay Allow con Principal "*" (anónimo / público)
  analysis=$(echo "$result" | jq -r '
    (. | fromjson? // .) as $pol
    | ($pol.Statement // [])
    | map(select(
        (.Effect == "Allow") and (
          (.Principal == "*") or
          (.Principal.AWS == "*") or
          ((.Principal.AWS | type) == "array" and (.Principal.AWS | index("*") != null)) or
          (.Principal.CanonicalUser == "*")
        )
      ))
    | if length == 0 then
        "OK_SIN_ANONIMO"
      else
        "ANONIMO|" + (map({
          Sid: (.Sid // null),
          Action: .Action,
          Resource: .Resource,
          Condition: (.Condition // null)
        }) | tostring)
      end
  ' 2>/dev/null) || analysis="ERROR_PARSE"

  case "$analysis" in
    OK_SIN_ANONIMO)
      echo "OK (sin anonimo): $bucket"
      ;;
    ANONIMO\|*)
      echo "POLITICA ANONIMA: $bucket"
      echo "${analysis#ANONIMO|}" | jq .
      ;;
    *)
      echo "ERROR PARSEANDO POLITICA: $bucket"
      ;;
  esac
done