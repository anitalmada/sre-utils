# sre-utils

Conjunto de utilidades para el día a día de un SRE: scripts que usan la API de AWS (vía AWS CLI) para **relevamientos** y, cuando corresponde, **modificaciones controladas** sobre recursos de la cuenta.

No es un producto ni un framework. Son herramientas operativas, pequeñas y explícitas, pensadas para auditar status de seguridad, justificar cambios y aplicar remediaciones con cuidado (dry-run primero).

**Idiomas:** [English](README.md) · Español (este archivo)

## Requisitos

- [AWS CLI](https://aws.amazon.com/cli/) v2 configurado (`aws configure` o `AWS_PROFILE`)
- [jq](https://jqlang.github.io/jq/) para parsear respuestas JSON
- Bash 4+
- Permisos IAM de lectura sobre los recursos a relevar; escritura solo si vas a usar scripts de remediación (`--apply`)

## Estructura

```text
sre-utils/
└── aws/
    └── s3/          # Buckets: acceso público, ACLs, cifrado
```

La idea es agrupar por servicio (`aws/s3`, y más adelante `aws/ec2`, `aws/iam`, etc.) a medida que se sumen utilidades.

## Scripts actuales (S3)

| Script | Modo | Qué hace |
|--------|------|----------|
| `bucketAccessList.sh` | Solo lectura | Releva Block Public Access (BPA) por bucket |
| `bucketAnonymousPolicies.sh` | Solo lectura | Detecta políticas con `Principal: "*"` (acceso anónimo). Excluye `*-public-*` |
| `bucketAclSurvey.sh` | Solo lectura | Releva Object Ownership y ACLs (AllUsers / AuthenticatedUsers) |
| `bucketEncryptionSurvey.sh` | Solo lectura | Releva cifrado por defecto (SSE-KMS, SSE-S3 o sin default) |
| `bucketEnableSseKms.sh` | Dry-run / `--apply` | Planifica o aplica cifrado por defecto SSE-KMS. Excluye `*-public` |

### Ejemplos

```bash
export AWS_PROFILE=mi-cuenta

# Relevamientos
./aws/s3/bucketAccessList.sh
./aws/s3/bucketAnonymousPolicies.sh
./aws/s3/bucketAclSurvey.sh | tee relevamiento-acl-$(date +%Y%m%d).txt
./aws/s3/bucketEncryptionSurvey.sh

# Remediación: primero dry-run, después apply
./aws/s3/bucketEnableSseKms.sh
./aws/s3/bucketEnableSseKms.sh --apply
./aws/s3/bucketEnableSseKms.sh --apply --cmk alias/mi-clave-s3
```
## Output de ejemplo

Command: `./aws/s3/bucketAccessList.sh`
```
BPA ACTIVO: codepipeline-us-east-1-123456789012
BPA INCOMPLETO: demo-sre-utilities
{
  "BlockPublicAcls": false,
  "IgnorePublicAcls": false,
  "BlockPublicPolicy": false,
  "RestrictPublicBuckets": false
}
SIN BPA: elasticbeanstalk-us-east-1-123456789012 (sin configuración)
BPA ACTIVO: sre-utilities-bpa
```

## Criterios de diseño

- **Relevar antes de cambiar.** La mayoría de los scripts son de solo lectura.
- **Dry-run por defecto** en scripts que mutan estado.
- **Exclusiones explícitas** cuando un patrón de nombre implica acceso público intencional (p. ej. buckets `*-public*`), para no romper apps que sirven archivos por URL.
- **Salida legible en terminal**, apta para pegar en tickets o reportes (`tee`).

## Alcance y límites

- Operan a nivel de **cuenta / perfil** configurado en la CLI.
- No reemplazan CSPM, Config Rules ni IaC: complementan el trabajo manual y la evidencia de remediación.
- Revisá siempre el impacto en aplicaciones (URLs públicas, KMS/SigV4, ACLs vs bucket policies) antes de `--apply`.

## Contribuciones

Sumá scripts nuevos bajo `aws/<servicio>/`, documentá uso y modo (lectura vs write) en este README, y preferí dry-run por defecto cuando el script modifique recursos.
