#!/usr/bin/env bash
# Relevamiento: ACLs y Object Ownership de buckets S3 (solo lectura).
# Objetivo: ver dónde hay ACL públicas / ownership con ACL habilitadas
# sin modificar nada (no rompe acceso de la app).
#
# Uso:
#   ./bucketAclSurvey.sh
#   ./bucketAclSurvey.sh | tee relevamiento-acl-$(date +%Y%m%d).txt

set -euo pipefail

echo "=== Relevamiento ACLs / Object Ownership S3 ==="
echo "Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Cuenta/perfil: ${AWS_PROFILE:-default}"
echo "Modo: SOLO LECTURA (no aplica cambios)"
echo

owner_enforced=0
acl_enabled=0
public_acl=0
auth_users_acl=0
sin_acl_info=0
errores=0
public_name=0

for bucket in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  is_public_name=0
  rule=""
  if [[ "$bucket" == *-public ]] || [[ "$bucket" == *-public-* ]]; then
    is_public_name=1
    public_name=$((public_name + 1))
  fi

  echo "---- $bucket$([[ $is_public_name -eq 1 ]] && echo '  [bucket público por nombre]') ----"

  # --- Object Ownership ---
  own=$(aws s3api get-bucket-ownership-controls --bucket "$bucket" 2>&1) || true
  if echo "$own" | grep -q "OwnershipControlsNotFoundError"; then
    ownership="NO CONFIG (ACL tipicamente habilitadas / legacy)"
    acl_enabled=$((acl_enabled + 1))
  elif echo "$own" | grep -qi "AccessDenied\|Unauthorized\|error"; then
    ownership="ERROR leyendo ownership"
    errores=$((errores + 1))
  else
    rule=$(echo "$own" | jq -r '.OwnershipControls.Rules[0].ObjectOwnership // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    case "$rule" in
      BucketOwnerEnforced)
        ownership="BucketOwnerEnforced (ACLs DESHABILITADAS)"
        owner_enforced=$((owner_enforced + 1))
        ;;
      BucketOwnerPreferred)
        ownership="BucketOwnerPreferred (ACLs habilitadas; owner preferido)"
        acl_enabled=$((acl_enabled + 1))
        ;;
      ObjectWriter)
        ownership="ObjectWriter (ACLs habilitadas; writer = owner del objeto)"
        acl_enabled=$((acl_enabled + 1))
        ;;
      *)
        ownership="$rule"
        acl_enabled=$((acl_enabled + 1))
        ;;
    esac
  fi
  echo "  Ownership: $ownership"

  # Con ACLs deshabilitadas no hay grants que relevar
  if [[ "$rule" == "BucketOwnerEnforced" ]]; then
    echo "  Bucket ACL: no aplicable (ACLs deshabilitadas en el bucket)"
    echo
    continue
  fi

  # --- Bucket ACL ---
  # Importante: capturar stdout/stderr por separado. No usar grep "error" genérico
  acl_err=$(mktemp)
  acl=$(aws s3api get-bucket-acl --bucket "$bucket" --output json 2>"$acl_err") && acl_rc=0 || acl_rc=$?
  err_txt=$(cat "$acl_err" 2>/dev/null || true)
  rm -f "$acl_err"

  if [[ $acl_rc -ne 0 ]]; then
    if echo "$err_txt" | grep -qi "AccessControlListNotSupported\|does not allow ACLs"; then
      echo "  Bucket ACL: no aplicable (ACLs deshabilitadas en el bucket)"
    elif echo "$err_txt" | grep -qi "AccessDenied\|Unauthorized"; then
      echo "  Bucket ACL: ERROR/SIN PERMISO"
      echo "    $(echo "$err_txt" | tr '\n' ' ' | head -c 160)"
      errores=$((errores + 1))
    else
      echo "  Bucket ACL: ERROR al consultar"
      echo "    $(echo "$err_txt" | tr '\n' ' ' | head -c 160)"
      errores=$((errores + 1))
    fi
    echo
    continue
  fi

  analysis=$(echo "$acl" | jq -c '
    . as $root
    | ($root.Grants // []) as $g
    | {
        all_users: [
          $g[]
          | select((.Grantee.URI // "") | endswith("AllUsers"))
          | .Permission
        ],
        authenticated_users: [
          $g[]
          | select((.Grantee.URI // "") | endswith("AuthenticatedUsers"))
          | .Permission
        ],
        other_grants: [
          $g[]
          | select(
              ((.Grantee.URI // "") | endswith("AllUsers") | not)
              and ((.Grantee.URI // "") | endswith("AuthenticatedUsers") | not)
            )
          | {
              perm: .Permission,
              type: (.Grantee.Type // null),
              id: (.Grantee.ID // .Grantee.EmailAddress // .Grantee.URI // null)
            }
        ]
      }
  ' 2>/dev/null) || analysis=""

  if [[ -z "$analysis" ]]; then
    echo "  Bucket ACL: ERROR parseando JSON"
    echo "    $(echo "$acl" | tr '\n' ' ' | head -c 160)"
    sin_acl_info=$((sin_acl_info + 1))
    echo
    continue
  fi

  all_users=$(echo "$analysis" | jq -r '.all_users | join(",")')
  auth_users=$(echo "$analysis" | jq -r '.authenticated_users | join(",")')
  other_count=$(echo "$analysis" | jq -r '.other_grants | length')

  if [[ -n "$all_users" ]]; then
    echo "  ACL PUBLICA (AllUsers): $all_users"
    public_acl=$((public_acl + 1))
  else
    echo "  ACL AllUsers: (ninguno)"
  fi

  if [[ -n "$auth_users" ]]; then
    echo "  ACL AuthenticatedUsers: $auth_users"
    auth_users_acl=$((auth_users_acl + 1))
  else
    echo "  ACL AuthenticatedUsers: (ninguno)"
  fi

  echo "  Otros grants (no AllUsers/AuthenticatedUsers): $other_count"
  if [[ "$other_count" != "0" ]]; then
    echo "$analysis" | jq '.other_grants'
  fi

  echo
done

echo "=== Resumen ==="
echo "Buckets nombre *-public:              $public_name"
echo "Ownership BucketOwnerEnforced (sin ACL): $owner_enforced"
echo "Ownership con ACL habilitadas / legacy:  $acl_enabled"
echo "Bucket ACL con AllUsers (publica):       $public_acl"
echo "Bucket ACL con AuthenticatedUsers:       $auth_users_acl"
echo "Errores / sin permiso:                   $errores"
