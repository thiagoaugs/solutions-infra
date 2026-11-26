# Deploy no Google Cloud (GCP)

## Ambientes: homologação e produção

São **dois projetos GCP separados**, com a **mesma arquitetura** e os **mesmos scripts**. Só a configuração muda
(`gcp/ambientes/homologacao.env` e `producao.env`, neste repositório `solutions-infra`).

| | **Homologação** (testes) | **Produção** |
|---|---|---|
| Para que serve | testar cada mudança como se fosse a produção | o sistema que as barracas usam |
| Projeto GCP | próprio (ex.: `swell-homologacao`) | próprio (ex.: `swell-producao`) |
| Quando é publicado | **automaticamente a cada push na `main`** | **ao criar uma tag de versão** (`v1.2.3`) |
| Banco (Cloud SQL) | `db-f1-micro`, **sem backups** | `db-g1-small`, backups diários (14 dias), proteção contra exclusão |
| Horário ligado | **nunca liga sozinho**: só quando alguém acorda para testar (2h, depois hiberna) | todo dia 7h–20h (ajustável) |
| API | até 1 instância | até 4 instâncias (ver "Escalar") |
| Dados | barraca de exemplo ("Barraca do Sol"); **nunca copie dados da produção** | reais |
| Telas | faixa amarela **"🧪 AMBIENTE DE TESTES"** em todas as páginas | sem faixa |
| Quem pode publicar (GitHub) | só workflow rodando na `main` | só workflow rodando numa tag `v*` |

Por que dois projetos e não um só: dados, senhas, permissões e custos ficam totalmente separados. Um erro testando
na homologação (apagar o banco, trocar uma permissão) não tem como atingir a produção.

### Custo aproximado

Estimativa da ordem de grandeza, em US$ por mês, na região de São Paulo. Confira na
[calculadora do GCP](https://cloud.google.com/products/calculator) com as suas escolhas: os preços mudam.

| Peça | Homologação (hibernada, ~10 h de teste/mês) | Produção (ligada 13 h/dia) |
|---|---|---|
| Cloud SQL | disco de 10 GB (~2–3) + horas ligadas (centavos) | instância `db-g1-small` só nas horas ligadas + disco + backups (~20–35) |
| Cloud Run (API + Keycloak) | ~0 (escala a zero; cobrado só enquanto testa) | instâncias mínimas no horário (~15–40, depende do tráfego) |
| Firebase Hosting, Scheduler, Secret Manager, Artifact Registry | ~0–1 (faixa gratuita) | ~1–3 |
| **Total** | **≈ US$ 3–5** | **≈ US$ 40–80** |

Para economizar mais na produção: tirar a instância mínima da API (`SERVICOS_SEMPRE_PRONTOS="praia-keycloak"`) troca
alguns dólares por uma espera de poucos segundos no 1º pedido do dia.

### Fluxo do dia a dia

```
 PR aberto ──► testes (CI)
 merge na main ──► testes ──► deploy na HOMOLOGAÇÃO (API e telas, cada repositório o seu)
                                   │  acorde a homologação e teste no celular
                                   ▼
 tag v1.2.3 ──► testes ──► deploy na PRODUÇÃO
```

1. Faça merge na `main` nos dois repositórios (API e frontend). O GitHub publica na homologação.
2. Acorde a homologação para testar (ela fica dormindo para não custar):
   ```powershell
   .\gcp\despertador.ps1 homologacao acordar      # liga por 2h e volta a dormir sozinha
   ```
   Abra `https://<projeto-de-homologacao>.web.app` (a faixa amarela confirma que é o ambiente de testes).
3. Tudo certo? Crie a **mesma tag** nos dois repositórios (API e frontend), a partir do commit testado:
   ```powershell
   git tag v1.2.3
   git push origin v1.2.3
   ```
   Ou pelo GitHub: *Releases → Draft a new release → Choose a tag → v1.2.3*.
4. Para voltar uma versão na produção: crie uma tag nova a partir do commit anterior (`git tag v1.2.4 <commit>`),
   ou volte o tráfego no Console: *Cloud Run → praia-api → Revisões → Gerenciar tráfego*.

Ordem quando a versão muda a API e as telas juntas: publique a **API primeiro** (as telas novas podem depender
dela; a API nova continua aceitando as telas antigas).

## Arquitetura (igual nos dois ambientes)

```
 Cliente (QR Code) / Equipe
          │  HTTPS
          ▼
 Firebase Hosting ───────── telas Angular (repo solutions-praia-frontend; sempre no ar, mostram "fechado")
          │  /api/**
          ▼
 Cloud Run: praia-api ─────────┐            Cloud Run: praia-keycloak ◄── login das telas (PKCE)
   escala a zero sozinha       │              1 instância, cache local
                               ▼  IP privado (Direct VPC egress)
                     Cloud SQL PostgreSQL 16 (sem IP público)
                       bancos: praia (RLS) + keycloak
                               ▲
 Cloud Scheduler (15 em 15 min) ─► Cloud Run Job: praia-despertador ─► liga/desliga banco e instâncias mínimas
```

Região: `southamerica-east1` (São Paulo). Segredos: Secret Manager. Imagens: Artifact Registry. Cada ambiente
tem tudo isso no próprio projeto.

## Primeira instalação

Faça **primeiro a homologação** e, quando estiver funcionando, repita para a produção.

1. No Console do GCP, crie os dois projetos (ex.: `swell-homologacao` e `swell-producao`), os dois ligados à sua
   conta de faturamento.
2. Ajuste os arquivos de ambiente: pelo menos `PROJETO` e `ADMIN_EMAIL` em
   `gcp/ambientes/homologacao.env` e `gcp/ambientes/producao.env`. Faça commit.
3. Abra o **Cloud Shell** (tem gcloud, docker, node e envsubst) e clone **os repositórios lado a lado** (o deploy
   pega o código da API na pasta irmã `../solutions-praia-api`):
   ```bash
   git clone https://github.com/SEU-USUARIO/solutions-infra.git
   git clone https://github.com/SEU-USUARIO/solutions-praia-api.git
   cd solutions-infra
   ```
   Crie a infraestrutura. Os dois últimos argumentos liberam o deploy pelo GitHub (seguro rodar de novo):
   ```bash
   bash gcp/setup.sh homologacao SEU-USUARIO/solutions-praia-api SEU-USUARIO/solutions-praia-frontend
   ```
4. Primeiro deploy do backend (API, Keycloak, despertador). Com a API em outra pasta, use `API_DIR=<pasta>`:
   ```bash
   bash gcp/deploy.sh homologacao
   ```
   No Cloud Shell, as imagens são montadas pelo **Cloud Build**, dentro da rede do Google: só o código sobe. O Cloud
   Shell limita conexões, e enviar imagens grandes com `docker push` falha com "connection refused" no Artifact
   Registry. No GitHub Actions o deploy usa `docker` normalmente. Para forçar um dos dois: `CONSTRUIR_COM=docker` ou
   `CONSTRUIR_COM=cloudbuild`. Se o deploy for repetido depois de uma falha, as imagens que já estão no registro são
   reaproveitadas.
5. Publique as telas pelo repositório `solutions-praia-frontend` (push na `main`, ou
   `npx ng build && npx firebase-tools@13 deploy --only hosting --project <PROJETO>`).
6. Entre em `https://<PROJETO>.web.app/admin` com o usuário **admin** e a senha inicial:
   ```bash
   gcloud secrets versions access latest --secret praia-admin-senha-inicial --project <PROJETO>
   ```
   O Keycloak obriga a trocar a senha no 1º login. Depois cadastre as barracas (já com o gerente de cada uma).
7. Repita os passos 3 a 6 com `producao`. Rodando à mão na produção, o script pede para digitar o ID do projeto,
   para ninguém publicar lá por engano.

### Deploy contínuo (GitHub Actions)

Os repositórios são privados no plano gratuito do GitHub, onde os *Environments* não estão disponíveis. Por isso cada
ambiente usa **variáveis do repositório com o nome do ambiente no final**. Em **cada um dos dois repositórios** (API e
frontend): *Settings → Secrets and variables → Actions → Variables → New repository variable*. O `setup.sh` de cada
ambiente imprime os valores no final:

| Variável | O que é |
|---|---|
| `GCP_PROJETO_HOMOLOGACAO` / `GCP_PROJETO_PRODUCAO` | ID do projeto GCP do ambiente |
| `GCP_WIF_PROVIDER_HOMOLOGACAO` / `GCP_WIF_PROVIDER_PRODUCAO` | provedor do Workload Identity Federation do projeto |
| `GCP_DEPLOYER_SA_HOMOLOGACAO` / `GCP_DEPLOYER_SA_PRODUCAO` | conta de serviço `praia-deployer` do projeto |
| `DEPLOY_GCP` = `true` | liga os deploys (sem ela, os pushes rodam só os testes e os deploys aparecem como "skipped") |

Se faltar alguma variável, o deploy para logo no primeiro passo dizendo qual é.

O workflow da **API** baixa este repositório (`solutions-infra`) para rodar o `gcp/deploy.sh`. Como ele é **privado**,
crie no repositório da API o segredo `INFRA_REPO_TOKEN` (*Settings → Secrets and variables → Actions → Secrets*) com
um token de leitura deste repositório (GitHub → *Settings → Developer settings → Fine-grained tokens*, acesso só a
`solutions-infra`, permissão *Contents: Read*, validade de 1 ano). O frontend não precisa: ele só publica no Firebase.

Mudanças aqui (horário, tamanho do banco, limites) valem no **próximo deploy** de cada ambiente: um push na `main`
da API (homologação) ou uma tag nova (produção). Para aplicar sem esperar, rode `bash gcp/deploy.sh <ambiente>`.

Regras dos workflows:

- **Segurança:** não há chave de conta de serviço guardada no GitHub. O login usa Workload Identity Federation, e o
  próprio GCP só aceita deploy vindo da `main` (homologação) ou de uma tag `v*` (produção), dos seus dois
  repositórios. Só os jobs de deploy podem pedir esse login; os testes e os pull requests não.
- **Tempo:** cada job tem limite (testes 15–20 min, deploy 45 min), para um travamento não consumir os 2.000
  minutos/mês do plano gratuito.
- **Deploy rápido:** as imagens do Keycloak e do despertador levam o hash da própria pasta como tag; um push só na API
  reaproveita as duas do registro (não constrói nem reinicia o Keycloak). A imagem da API usa cache de camadas
  guardado no próprio Artifact Registry (`praia-api:cache`): com o `pom.xml` igual, só o código é recompilado.
  O primeiro deploy depois dessa mudança ainda constrói tudo uma vez (para criar as tags e o cache).
- **Trava do ambiente dormindo:** nos pushes que publicam (`main` e tags `v*`), o primeiro job (`ambiente`, ~20 s) lê
  pela API do Cloud SQL se o banco do ambiente de destino está ligado (`ALWAYS` + `RUNNABLE`). Se estiver hibernado,
  **testes e deploy são pulados** e a execução termina com o aviso "Ambiente dormindo" e as instruções no resumo.
  Antes, o `deploy.sh` acordava o ambiente e esperava (até 25 min) e o job acabava travando. Para publicar: acorde
  (`.\gcp\despertador.ps1 homologacao acordar` ou `bash gcp/despertador-cli.sh homologacao acordar`), espere terminar
  e clique em **Re-run all jobs**. Pull requests não passam pela trava (só testes). O nome da instância é `praia-db`;
  se for outro, crie a variável do repositório `GCP_INSTANCIA_SQL`. Por segurança, o `deploy.sh` rodando no CI
  também para na hora (em vez de acordar) se encontrar o ambiente hibernado; rodando à mão, continua acordando por 1h.
- **Ordem numa versão nova:** crie a tag primeiro na API, espere o deploy dela terminar e só então no frontend.
- **Este repositório** (`solutions-infra`) tem o workflow *Verificar*: shellcheck e `gcp/testes/verificar.sh`
  (sintaxe, ambientes, arquivos do Cloud Run e o despertador com um gcloud simulado), sem acessar o GCP. Rode o mesmo
  antes do push: `bash gcp/testes/verificar.sh`.
- **Sem proteção de branch:** no plano gratuito, em repositório privado, o GitHub não impede push na `main` com teste
  quebrado. O deploy não roda se os testes falharem, mas o código entra na `main`. Prefira trabalhar em branch e
  abrir pull request, olhando os testes antes do merge.

### Domínio próprio

Preencha `DOMINIO` no arquivo do ambiente (ex.: `swell.app` na produção, `teste.swell.app` na homologação),
conecte o domínio no Console do Firebase daquele projeto (Hosting → Adicionar domínio personalizado) e faça deploy.
A URL do QR Code e a lista de endereços permitidos do login passam a usar o domínio.

Atenção: o endereço permitido no login (`redirectUris` do cliente `praia-web`) é gravado **só na primeira** subida
do Keycloak. Se trocar de domínio depois, ajuste no console do Keycloak: realm `praia` → Clients → `praia-web` →
Valid redirect URIs.

## Hibernação (economia fora do horário)

| Peça | Ligado | Hibernado |
|---|---|---|
| Cloud SQL | ligado (`ALWAYS`) | **parado** (`NEVER`): paga só o disco |
| Keycloak | 1 instância mínima | **0 instâncias** |
| API | 1 instância mínima (sem espera no 1º acesso) | **0 instâncias** (escala a zero) |
| Telas (Firebase) | no ar | no ar, mostrando "Estamos fechados agora. Atendimento das 8h às 18h." |

O despertador de cada ambiente roda a cada 15 min e decide pelo relógio de São Paulo. Na produção, liga no horário
configurado; na homologação (`DIAS="0"`), **só liga quando alguém acorda**. Tudo é idempotente.

### Acordar fora do horário (ou para testar)

Do seu computador (Windows), com o `gcloud` logado:

```powershell
.\gcp\despertador.ps1 homologacao acordar      # liga a homologação por 2h
.\gcp\despertador.ps1 homologacao acordar 4    # por 4h
.\gcp\despertador.ps1 homologacao hibernar     # desliga agora
.\gcp\despertador.ps1 producao acordar 6       # produção fora do horário, por 6h (pede confirmação)
.\gcp\despertador.ps1 producao status
```

No Cloud Shell / Linux: `bash gcp/despertador-cli.sh homologacao acordar 2`.

Pelo navegador (inclusive celular): Console do GCP (escolha o projeto) → **Cloud Run → Jobs → praia-despertador →
Executar com substituições** → argumentos `acordar` e `3`.

- Ligar leva de **1 a 3 minutos** (o banco é o mais lento).
- Passado o prazo, o próprio agendamento hiberna de novo. Não precisa lembrar de desligar.
- Produção desligada num dia inteiro (chuva, feriado):
  `gcloud scheduler jobs pause praia-despertador --location southamerica-east1 --project <PROJETO>` e depois `... resume`.

### Mudar o horário ou os dias

Edite o arquivo do ambiente (`HORA_ACORDAR`, `HORA_HIBERNAR`, `DIAS`, `SERVICOS_SEMPRE_PRONTOS`) e faça deploy.
Para mudar na hora, sem deploy:

```powershell
gcloud run jobs update praia-despertador --region southamerica-east1 --project <PROJETO> --update-env-vars HORA_HIBERNAR=22
```

O horário mostrado aos clientes na tela de "fechado" fica no frontend, em `src/app/core/config.ts`.

### Para não esquecer

- Backups automáticos da produção rodam às **7h30** (Brasília), quando o banco já está ligado.
- Com o banco hibernado, **ninguém usa o sistema**, nem a equipe (ex.: gerente ajustando preços às 22h): acorde antes.
- Um deploy com o ambiente hibernado acorda o ambiente por 1h automaticamente (por isso cada merge na `main`
  liga a homologação por 1h; ela volta a dormir sozinha).

## Escalar

A API escala sozinha até `MAX_API` instâncias (cada uma com 80 requisições simultâneas). Para mais capacidade na
produção: aumente `MAX_API` e, junto, o `SQL_TIER` (o banco precisa aguentar as conexões: cada instância da API usa
até 5, o Keycloak até 10). Trocar o tier aplica com alguns minutos fora do ar; faça fora do horário.

## Avisos no celular da equipe (push)

- **App web instalada (PWA)**: Web Push padrão com chaves VAPID, que o `setup.sh` gera no Secret Manager de cada
  projeto. Nada a configurar no Firebase. Cada ambiente tem as próprias chaves: o celular ativa os avisos
  separadamente na homologação e na produção.
- **App Android nativo** (futuro): usa o Firebase Cloud Messaging do **mesmo projeto**. O `setup.sh` já ativa a API do
  FCM e dá à conta `praia-api` o papel *Firebase Cloud Messaging API Admin*. No Console do Firebase → Configurações do
  projeto → **Adicionar app Android** com o pacote `br.com.solutions.praia.equipe` (um app para cada ambiente, ou um
  *build flavor* por ambiente).

Se o realm `praia` já existia antes do app Android, crie o cliente `praia-android` no console do Keycloak: público,
Standard flow, PKCE S256, redirect `br.com.solutions.praia.equipe:/oauth2redirect` e o mapper de grupos igual ao do
`praia-web`. Realms novos já vêm com ele.

## Segurança em produção

- Banco **sem IP público**, só acessível pela rede privada; conexões com TLS obrigatório.
- A aplicação conecta com `praia_app` (criado pelo Flyway, sem `SUPERUSER`/`BYPASSRLS`): o Row-Level Security vale para ela.
- Cada serviço tem conta de serviço própria e lê só os próprios segredos.
- Keycloak: realm sem usuários de teste, admin inicial com troca obrigatória de senha, bloqueio após 5 senhas erradas.
- Swagger desligado em produção; só o health check do Actuator fica exposto (sem detalhes).
- Homologação e produção não compartilham nada: senhas, chaves VAPID e usuários são diferentes em cada projeto.

Depois do primeiro deploy de cada ambiente:

- Entre no console do Keycloak (`https://praia-keycloak-....run.app`, usuário `bootstrap-admin`, senha no segredo
  `keycloak-bootstrap-password`), crie um administrador permanente no realm `master` e desative o `bootstrap-admin`.

## Pontos a confirmar no seu projeto

- **Firebase Hosting → Cloud Run em `southamerica-east1`**: confira se a região aparece na lista de regiões aceitas
  pelos rewrites do Firebase. Se não aparecer, a alternativa é colocar a API em uma região aceita ou usar um Load
  Balancer na frente.
- **Políticas da organização**: se o projeto estiver numa organização com *Domain restricted sharing*, o acesso
  público (`allUsers`) aos serviços é bloqueado e precisa de exceção.
