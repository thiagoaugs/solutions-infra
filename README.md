# solutions-infra

Infraestrutura do **Swell** (pedidos pelo QR Code nas barracas de praia) no Google Cloud: scripts, configuração dos
ambientes e a imagem do Keycloak. O código da aplicação fica nos outros repositórios:

| Repositório | O que tem |
|---|---|
| `solutions-praia-api` | API Java (Spring Boot), vira a imagem `praia-api` |
| `solutions-praia-frontend` | Telas Angular, publicadas no Firebase Hosting |
| **`solutions-infra`** (este) | como e onde tudo roda: GCP, ambientes, Keycloak, hibernação |

## Ambientes

Dois projetos GCP separados, com a mesma arquitetura e os mesmos scripts:

- **homologação**: testes, publicada a cada push na `main` da API/frontend, hibernada até alguém acordar
  (≈ US$ 3–5/mês);
- **produção**: publicada por tag de versão (`v1.2.3`).

Passo a passo, custos, fluxo de publicação e segurança: **[docs/deploy-gcp.md](docs/deploy-gcp.md)**.

## Estrutura

```
gcp/
  ambientes/homologacao.env   configuração de cada ambiente (projeto, tamanho do banco, horários...)
  ambientes/producao.env
  ambiente.sh                 carrega o ambiente (obrigatório; produção pede confirmação no terminal)
  setup.sh                    cria a infraestrutura de um ambiente (uma vez)
  deploy.sh                   publica API, Keycloak e despertador (usa o código da API em ../solutions-praia-api)
  servicos/api.yaml           Cloud Run da API
  servicos/keycloak.yaml      Cloud Run do Keycloak
  despertador/                Cloud Run Job que liga/hiberna o ambiente fora do horário
  despertador.ps1             atalho no Windows: acordar/hibernar/status
  despertador-cli.sh          o mesmo no Cloud Shell/Linux
keycloak/
  Dockerfile, realm-praia.json   Keycloak de produção (realm sem usuários de teste)
docs/
  deploy-gcp.md
```

## Uso rápido

Com os repositórios lado a lado (`C:\DEV\REPO\solutions-infra` e `C:\DEV\REPO\solutions-praia-api`):

```powershell
.\gcp\despertador.ps1 homologacao acordar      # liga a homologação por 2h para testar
.\gcp\despertador.ps1 producao status
```

```bash
bash gcp/setup.sh homologacao SEU-USUARIO/solutions-praia-api SEU-USUARIO/solutions-praia-frontend   # 1ª vez
bash gcp/deploy.sh homologacao                                                                      # deploy à mão
```

O desenvolvimento local (PostgreSQL e Keycloak no Docker) continua no repositório da API (`docker-compose.yml`).
Sem segredos aqui: todos ficam no Secret Manager de cada projeto.
