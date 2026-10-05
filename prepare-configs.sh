#!/bin/sh

script_path=$(cd "$(dirname "${0}")" && pwd)
cd "${script_path}" || exit

# Carrega variáveis do .env
if [ -f ./.env ]; then
    . ./.env
else
    echo "Erro: Arquivo .env não encontrado."
    exit 1
fi

# Processa argumentos de linha de comando
while getopts 'v:' OPTION; do
  case "$OPTION" in
    v)
      VERSION="$OPTARG"
      ;;
    ?)
      echo "script usage: ./prepare-configs.sh [-v keaversion]" >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND -1))"

if [ -z "$VERSION" ]; then
    echo "Erro: Versão do Kea não definida."
    exit 1
fi

echo "Kea version selected: $VERSION"

# Baixa script SQL do PostgreSQL
echo "Baixando script de inicialização do banco de dados..."
mkdir -p initdb
TAG="Kea-$(echo "${VERSION}" | cut -d '.' -f 1).$(echo "${VERSION}" | cut -d '.' -f 2).$(echo "${VERSION}" | cut -d '.' -f 3)"
URL="https://gitlab.isc.org/isc-projects/kea/raw/${TAG}/src/share/database/scripts/pgsql/dhcpdb_create.pgsql"
wget -q --show-progress "${URL}" -O ./initdb/dhcpdb_create.sql

# Gera configurações
mkdir -p config/kea

echo "Gerando config/kea/subnets4.json..."
cat > "config/kea/subnets4.json" <<EOF
"subnet4": [
    {
        "id": ${SUBNET4_POOL_ID},
        "subnet": "${SUBNET4_POOL}",
        "pools": [
            {
                "pool": "${POOL4}"
            }
        ],
        "option-data": [
            {
                "name": "routers",
                "data": "${ROUTER4}"
            },
            {
                "name": "domain-name-servers",
                "data": "${DNS4}"
            },
            {
                "name": "domain-search",
                "data": "${DOMAIN_SEARCH4}"
            }
        ],
        "interface": "eth0"
    }
]
EOF

echo "Gerando config/kea/subnets6.json..."
cat > "config/kea/subnets6.json" <<EOF
"subnet6": [
    {
        "id": ${SUBNET6_POOL_ID},
        "subnet": "${SUBNET6_POOL}",
        "pools": [
            {
                "pool": "${POOL6}"
            }
        ],
        "option-data": [
            {
                "name": "dns-servers",
                "data": "${DNS6}"
            },
            {
                "name": "domain-search",
                "data": "${DOMAIN_SEARCH6}"
            }
        ],
        "interface": "eth0"
    }
]
EOF

echo "Configurações geradas com sucesso!"