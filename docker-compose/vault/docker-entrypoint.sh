#!/usr/bin/dumb-init /bin/sh
set -e
ulimit -c 0

DOMAIN_NAME="127.0.0.1"
PORT="8200"
VAULT_CONFIG_DIR="/etc/vault.d"
VAULT_DATA_DIR="/var/lib/vault"
VAULT_TMP_DIR="/vault/tmp"
UNSEAL_KEY_1_FILE="/vault/tmp/unseal_key-1"
UNSEAL_KEY_2_FILE="/vault/tmp/unseal_key-2"
UNSEAL_KEY_3_FILE="/vault/tmp/unseal_key-3"
ROOT_TOKEN_FILE="/vault/tmp/root_token"

# Préparation des répertoires
mkdir -p $VAULT_CONFIG_DIR $VAULT_DATA_DIR $VAULT_TMP_DIR
chown -R vault:vault $VAULT_CONFIG_DIR $VAULT_DATA_DIR $VAULT_TMP_DIR

export VAULT_ADDR="http://127.0.0.1:$PORT"

if test -f "$VAULT_CONFIG_DIR/vault.hcl"; then
  VAULT_STATUS="true"
else
  VAULT_STATUS="false"
fi

echo "VAULT_STATUS : $VAULT_STATUS"

# Vérifier si Vault est déjà initialisé
if "$VAULT_STATUS"; then

  echo "Vault est déjà initialisé."

  # Lancer Vault
  echo "Vault n'est pas encore démarré. Lancement de Vault..."
  vault server -config=$VAULT_CONFIG_DIR &
  VAULT_PID=$!

  sleep 5

  # Sauvegarder les clés et le token dans des fichiers sécurisés
  UNSEAL_KEY_1=$(cat "$UNSEAL_KEY_1_FILE")
  UNSEAL_KEY_2=$(cat "$UNSEAL_KEY_2_FILE")
  UNSEAL_KEY_3=$(cat "$UNSEAL_KEY_3_FILE")
  ROOT_TOKEN=$(cat "$ROOT_TOKEN_FILE")

  echo "Clés de déverrouillage et token root enregistrés."

  # Déverrouiller Vault avec les clés d'unseal
  vault operator unseal $UNSEAL_KEY_1
  vault operator unseal $UNSEAL_KEY_2
  vault operator unseal $UNSEAL_KEY_3
  vault login $ROOT_TOKEN

  touch /tmp/service_started

  tail -f /dev/null

else
  echo "Vault n'est pas initialisé. Initialisation en cours..."

  # Configuration de Vault pour un backend de fichiers simple
  cat <<EOF >$VAULT_CONFIG_DIR/vault.hcl
storage "file" {
  path = "/var/lib/vault"
}
listener "tcp" {
  address     = "0.0.0.0:$PORT"
  tls_disable = 1
}
api_addr = "http://127.0.0.1:$PORT"
ui = true
EOF

  # Lancer Vault
  echo "Vault n'est pas encore démarré. Lancement de Vault..."
  vault server -config=$VAULT_CONFIG_DIR &
  VAULT_PID=$!

  sleep 5

  # Initialiser Vault et récupérer la sortie JSON
  INIT_OUTPUT=$(vault operator init -format=json -key-shares=3 -key-threshold=3)
  echo "Etape 1 : Initialisation de Vault ============================================================================"

  CLEANED_OUTPUT=$(echo "$INIT_OUTPUT" | sed -E 's/^[0-9:-]+\s*//')

  # Extraction du root token et des unseal keys
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep -o '"root_token": *"[^"]*"' | awk -F '": "' '{print $2}' | tr -d '"')

  # Extraction des UNSEAL_KEYs
  UNSEAL_KEY_1=$(echo "$CLEANED_OUTPUT" |
    tr -d '\n' |
    sed -n 's/.*"unseal_keys_b64":\s*\[\([^]]*\)\].*/\1/p' |
    tr ',' '\n' |
    sed -n '1p' |
    tr -d '"' |
    xargs)

  UNSEAL_KEY_2=$(echo "$CLEANED_OUTPUT" |
    tr -d '\n' |
    sed -n 's/.*"unseal_keys_b64":\s*\[\([^]]*\)\].*/\1/p' |
    tr ',' '\n' |
    sed -n '2p' |
    tr -d '"' |
    xargs)

  UNSEAL_KEY_3=$(echo "$CLEANED_OUTPUT" |
    tr -d '\n' |
    sed -n 's/.*"unseal_keys_b64":\s*\[\([^]]*\)\].*/\1/p' |
    tr ',' '\n' |
    sed -n '3p' |
    tr -d '"' |
    xargs)

  # Sauvegarder les clés et le token dans des fichiers sécurisés
  echo "$UNSEAL_KEY_1" >$UNSEAL_KEY_1_FILE
  echo "$UNSEAL_KEY_2" >$UNSEAL_KEY_2_FILE
  echo "$UNSEAL_KEY_3" >$UNSEAL_KEY_3_FILE
  echo "$ROOT_TOKEN" >$ROOT_TOKEN_FILE

  chmod 777 $UNSEAL_KEY_1_FILE $UNSEAL_KEY_2_FILE $UNSEAL_KEY_3_FILE $ROOT_TOKEN_FILE

  echo "Clés de déverrouillage et token root enregistrés."

  # Déverrouiller Vault avec les clés d'unseal
  vault operator unseal $UNSEAL_KEY_1
  vault operator unseal $UNSEAL_KEY_2
  vault operator unseal $UNSEAL_KEY_3
  vault login $ROOT_TOKEN
fi

# Vérifier de nouveau l'état de Vault avant de continuer
if vault status | grep -q "Sealed: true"; then
  echo "Erreur : Vault est toujours scellé. Abandon du processus."
  exit 1
else
  echo "Vault est déverrouillé, on continue."
fi

export VAULT_TOKEN=$ROOT_TOKEN

# Configurer Vault Agent pour le renouvellement automatique
cat <<EOF >$VAULT_CONFIG_DIR/agent.hcl
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/vault/tmp/role-id"
      secret_id_file_path = "/vault/tmp/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/vault/tmp/agent-token"
    }
  }
}
cache {
  use_auto_auth_token = true
}
listener "tcp" {
  address = "127.0.0.1:8100"
  tls_disable = true
}
EOF

# Activer AppRole et configurer les rôles
vault auth enable approle
vault write -f auth/approle/role/my-role secret_id_ttl=8760h token_ttl=16h token_max_ttl=8760h
vault read -field role_id auth/approle/role/my-role/role-id >/vault/tmp/role-id
vault write -field secret_id -f auth/approle/role/my-role/secret-id >/vault/tmp/secret-id

# Activer des secrets et configurer des rôles de base
vault secrets enable -path=pki pki
vault secrets enable -path=secrets kv
vault secrets tune -max-lease-ttl=97600h pki
vault write -field=certificate pki/root/generate/internal \
  common_name=$DOMAIN_NAME \
  ttl=97600h
vault write pki/config/urls \
  issuing_certificates="http://127.0.0.1:$PORT/v1/pki/ca" \
  crl_distribution_points="http://127.0.0.1:$PORT/v1/pki/crl"
vault write pki/roles/$DOMAIN_NAME allowed_domains=$DOMAIN_NAME allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false max_ttl=8760h

# Créer une politique de base pour l'AppRole
cat <<EOF >policy.hcl
path "secrets/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "kv/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki_int/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

vault policy write test-policy policy.hcl
vault write auth/approle/role/my-role policies=test-policy ttl=8760h

vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int
vault write pki_int/roles//$DOMAIN_NAME allowed_domains=/$DOMAIN_NAME allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false max_ttl=8760h

# Finalisation
echo "Vault est configuré en mode production avec un renouvellement automatique."

touch /tmp/service_started

tail -f /dev/null
