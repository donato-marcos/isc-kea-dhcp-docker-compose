# 🐳 ISC Kea DHCP Server (v4 & v6) com PostgreSQL e IPvlan

Este repositório provisiona os serviços de **DHCPv4** e **DHCPv6** com o **ISC Kea DHCP** usando Docker Compose. Ele é baseado no repositório oficial da **ISC (Internet Systems Consortium)**, com pequenos ajustes:

- [kea-docker](https://gitlab.isc.org/isc-projects/kea-docker)
- [kea-compose](https://gitlab.isc.org/isc-projects/kea-docker/-/tree/master/kea-compose?ref_type=heads)

Os contêineres usam o driver **IPvlan (L2)** para ficarem diretamente na rede física, e todas as concessões de IP (*leases*) são gravadas em um banco **PostgreSQL**. Os escopos (pools) são gerados automaticamente a partir do arquivo `.env`.

## 🏗️ Arquitetura e Fluxo de Rede

Servidores DHCP precisam tratar pacotes de *broadcast* e *multicast*. Em vez do modo `host`, este projeto usa o **IPvlan**: cada contêiner Kea tem seu próprio endereço IP na rede, atrelado à interface física do host (`${ETH}`).

O ambiente usa duas redes:

1. **`kea-10-ipvlan` (rede de fronteira):** liga `kea4` e `kea6` à interface física do servidor, com IPs fixos dentro de `SUBNET4` e `SUBNET6`. Dentro dos contêineres é a `eth0`.
2. **`kea-20-backend` (rede interna):** rede bridge usada na comunicação entre `kea4`/`kea6` e o contêiner PostgreSQL (`db`). Dentro dos contêineres Kea é a `eth1`.

```text
       [ Clientes Físicos / Rede Local ]
                       │
                       ▼ (Broadcast / Multicast)
 ┌─────────────────────┴────────────────────────┐
 │                 Host Docker                  │
 │   ┌──────────────────────────────────────┐   │
 │   │       Interface Física (${ETH})      │   │
 └───┴──────────────────┬───────────────────┴───┘
                        │
         ┌──────────────┴──────────────┐
         │        Driver IPvlan        │
         └──────┬──────────────┬───────┘
                │              │
                ▼              ▼
   ┌─────────────────┐    ┌─────────────────┐
   │      kea4       │    │      kea6       │  ◄─── [Rede kea-10-ipvlan]
   │  IP: ${IP4}     │    │  IP: ${IP6}     │       (Escuta do serviço)
   └────────┬────────┘    └────────┬────────┘
            │                      │
            └──────────┬───────────┘
                       │ (Rede interna: kea-20-backend)
                       ▼
            ┌────────────────────┐
            │   PostgreSQL (db)  │  ◄─── [Banco keadb]
            │  Volume: database  │       (Persistência de leases)
            └────────────────────┘
```

| Serviço | Imagem                                                 | Função                             |
|---------|--------------------------------------------------------|------------------------------------|
| `kea4`  | `docker.cloudsmith.io/isc/docker/kea-dhcp4:${VERSION}` | Servidor DHCPv4 (`67/udp`)         |
| `kea6`  | `docker.cloudsmith.io/isc/docker/kea-dhcp6:${VERSION}` | Servidor DHCPv6 (`547/udp`)        |
| `db`    | `postgres:18.4-alpine3.24`                             | Armazena os leases (banco `keadb`) |

**Volumes:** `database` (dados do PostgreSQL), `kea4-var` e `kea6-var` (`/var/lib/kea`). O diretório `./config/kea` é montado em `/etc/kea` e `./initdb` em `/docker-entrypoint-initdb.d`.

## 📁 Estrutura do Repositório

```text
kea-dhcp/
├── config/
│   └── kea/
│       ├── kea-ctrl-agent.conf   # Control Agent (não usado pelo compose atual)
│       ├── kea-dhcp4.conf        # Servidor DHCPv4
│       ├── kea-dhcp6.conf        # Servidor DHCPv6
│       ├── subnets4.json         # Gerado pelo prepare-configs.sh
│       └── subnets6.json         # Gerado pelo prepare-configs.sh
├── docker-compose.yaml
├── .env                          # Variáveis (versão, interface, IPs, pools...)
├── initdb/
│   └── dhcpdb_create.sql         # Schema do PostgreSQL (baixado pelo script)
└── prepare-configs.sh            # Gera subnets*.json e baixa o schema SQL
```

## ✅ Pré-requisitos

- Docker e Docker Compose (plugin `docker compose`)
- `wget` no host (usado pelo `prepare-configs.sh`)
- Acesso à internet (download do schema SQL e das imagens)
- Interface de rede do host conectada ao segmento onde o DHCP vai atuar

## 🚀 Como Inicializar o Ambiente

### 1. Ajustar as variáveis de ambiente (`.env`)

Edite o `.env` na raiz do projeto conforme a sua rede. Preencha `ETH` com o nome da placa de rede física do host (ex.: `eth0`, `enp1s0`).

```env
# Versão do Kea
VERSION="3.1.9"
# Interface física do host
ETH="enp1s0"

# Rede dos contêineres (IPvlan)
IP4="172.16.11.253"
IP4_V6="fd00:172:16:11::253"   # IPv6 estático do kea4
SUBNET4="172.16.11.0/24"
IP6="fd00:172:16:11::252"
IP6_V4="172.16.11.252"         # IPv4 estático do kea6
SUBNET6="fd00:172:16:11::/64"

# Pools distribuídos aos clientes - IPv4
SUBNET4_POOL_ID="1"
SUBNET4_POOL="10.20.11.0/24"
POOL4="10.20.11.21-10.20.11.248"
ROUTER4="10.20.11.254"
DNS4="172.16.11.11, 1.1.1.1"
DOMAIN_SEARCH4="teste.local"

# Pools distribuídos aos clientes - IPv6
SUBNET6_POOL_ID="1"
SUBNET6_POOL="fd00:10:20:11::/64"
POOL6="fd00:10:20:11::100-fd00:10:20:11::1ff"
ROUTER6="fd00:10:20:11::254"
DNS6="fd00:172:16:11::11, 2606:4700:4700::1111"
DOMAIN_SEARCH6="teste.local"
```

> `IP4_V6` e `IP6_V4` fixam um endereço da "outra" família em cada contêiner, evitando conflito com o outro servidor ou com o pool DHCP.

### 2. Executar o script de preparação (`prepare-configs.sh`)

O script faz duas tarefas:

- Baixa do repositório da **ISC** o script SQL (`dhcpdb_create.sql`) compatível com a versão definida no `.env`, para a inicialização automática do PostgreSQL.
- Gera `subnets4.json` e `subnets6.json` a partir das variáveis de escopo do `.env`.

```bash
chmod +x prepare-configs.sh
./prepare-configs.sh
```

Para usar outra versão do Kea sem editar o `.env`:

```bash
./prepare-configs.sh -v 3.1.9
```

> ⚠️ `subnets4.json` e `subnets6.json` são **sobrescritos** a cada execução. Altere os valores pelo `.env`, não direto nesses arquivos.
> O `-v` só afeta o schema SQL baixado: as imagens do compose continuam usando o `VERSION` do `.env`.

### 3. Subir a infraestrutura

No primeiro boot, o PostgreSQL cria as tabelas do Kea a partir do script em `initdb/`.

```bash
docker compose up -d
```

### 4. Parar o ambiente

```bash
docker compose down        # mantém os dados
docker compose down -v     # remove também os volumes (leases inclusive)
```

> O schema só é aplicado quando o volume `database` está vazio. Para reaplicá-lo, use `down -v`.

## 🛠️ Validação e Monitoramento

### Verificar a saúde dos serviços

Os contêineres têm *healthchecks*. `kea4` e `kea6` só iniciam depois que o PostgreSQL estiver saudável (tabela `schema_version` criada):

```bash
docker compose ps
```

### Acompanhar os logs

```bash
docker compose logs -f
docker compose logs -f kea4
```

### Inspecionar as portas ativas

O Kea deve escutar em `67/UDP` (IPv4) e `547/UDP` (IPv6):

```bash
# Kea v4
docker compose exec kea4 netstat -an | grep :67

# Kea v6
docker compose exec kea6 netstat -an | grep :547
```

## ⚠️ Observações Importantes

- **Acesso do host aos contêineres:** com IPvlan, o próprio host **não consegue** se comunicar com os contêineres pela interface `parent` (limitação do driver). Teste a partir de outra máquina da rede.
- **Control Agent:** o `kea-ctrl-agent.conf` existe, mas o `docker-compose.yaml` atual não tem um serviço que o execute, e os sockets de controle não são compartilhados entre contêineres. Para usar a API REST (porta `8000`) é preciso adicionar um serviço `kea-ctrl-agent`.
- **DHCPv6:** o `kea-dhcp6.conf` usa o endereço fixo `eth0/fd00:172:16:11::252`. Se alterar `IP6` no `.env`, atualize também esse arquivo.
- **Ao alterar o `.env`:** rode novamente `./prepare-configs.sh` e recrie os contêineres com `docker compose up -d --force-recreate`.
- **Segurança:** a senha do PostgreSQL está em texto puro no `docker-compose.yaml`, `kea-dhcp4.conf` e `kea-dhcp6.conf`. Troque-a e evite versioná-la (Docker secrets, variáveis de ambiente ou `.gitignore`).

---
✍️ Baseado no repositório [isc-projects/kea-docker](https://gitlab.isc.org/isc-projects/kea-docker), com `prepare-configs.sh` adaptado do `build_images.sh` original.