# SDD: Backup total de servidor Coolify em arquivo único

Data: 01/10/2026
Autor: Wesley (Grupo Life Company) com Claude Opus 5
Status: implementado

## 1. Problema

Precisamos levantar um servidor Coolify inteiro em outra máquina sem perder nada:
nem o painel, nem os bancos de dados dos projetos, nem os arquivos que os
containers gravam em disco (upload de usuário, certificado, fila de e-mail,
configuração montada por bind).

O backup nativo do Coolify não resolve isso. Ele faz duas coisas apenas:

1. um `pg_dump` do banco interno do próprio Coolify (projetos, servidores,
   variáveis, histórico de deploy);
2. backup agendado por banco de dados gerenciado, um a um, se a pessoa
   configurou cada um.

A documentação oficial é explícita: o backup de instância **não** inclui dados de
aplicação, bancos e volumes. Ou seja, restaurar só ele devolve um painel bonito
apontando para dados que não existem mais.

## 2. Causas raiz do "backup que não restaura"

Quatro pontos derrubam uma restauração na prática. Todos viraram requisito aqui.

### 2.1 APP_KEY fora do dump

O Coolify cifra credencial e chave privada antes de gravar no banco. A chave
dessa cifra é o `APP_KEY` de `/data/coolify/source/.env`, e esse arquivo **não
entra** no `pg_dump`. Restaurar o banco sem o `APP_KEY` original devolve um
painel que abre e não consegue ler nenhum segredo: servidor não valida, deploy
não roda, integração não autentica.

### 2.2 Dado de aplicação mora em volume e em bind, não no banco do Coolify

Cada banco gerenciado ganha um volume Docker nomeado. Cada aplicação e cada
serviço podem ter volume nomeado e também pasta de host montada por bind, em
`/data/coolify/applications/<uuid>/` e `/data/coolify/services/<uuid>/`. Backup
que ignora `/var/lib/docker/volumes` e os binds perde o conteúdo dos projetos.

### 2.3 Cópia a quente de arquivo de banco não é consistente

Copiar `/var/lib/postgresql/data` com o Postgres escrevendo gera arquivo
rasgado: parte das páginas é de antes da escrita, parte é de depois. Dá para
restaurar e descobrir a corrupção semanas depois. As duas saídas corretas são
dump lógico com a ferramenta do próprio banco, ou parar o container antes de
copiar.

### 2.4 Ferramenta de dump que não existe dentro da imagem

O `mongodump` saiu das imagens oficiais do MongoDB desde a separação das
Database Tools (versão 100.x, a partir do servidor 4.4). Script que assume
`mongodump` presente falha calado no Mongo. Redis e ClickHouse também não têm um
`pg_dump` equivalente ao alcance de um `docker exec` simples.

## 3. Objetivo

Um script só, rodando como root no servidor Coolify, que entrega no final **um**
arquivo `.tar.gz` suficiente para reconstruir o servidor em outra máquina.

Critério de conclusão, verificável:

- o arquivo existe, passa em `gzip -t` e em `tar -tzf`, e tem SHA256 publicado;
- dentro dele estão `/data/coolify` inteiro, o `APP_KEY` isolado, dump lógico de
  todo banco que aceita dump, cópia de todo volume Docker da máquina, cópia de
  toda pasta de host montada em container, e o retrato do Docker (containers,
  redes, imagens, compose);
- o relatório final lista o que entrou, o que falhou e o que ficou só com cópia
  de arquivo em vez de dump lógico, sem esconder falha;
- existe um `RESTAURAR.md` gerado com os valores reais daquele servidor (versão
  do Coolify, lista de volumes, lista de bancos), na ordem certa de restauração.

## 4. Solução

### 4.1 Três camadas de garantia, não uma

A ideia central do script: não depender de uma única técnica.

| Camada | O que é | Garante |
|---|---|---|
| 1. Dump lógico | `pg_dumpall`, `mysqldump --single-transaction`, `mongodump --archive`, `SAVE` no Redis | Consistência transacional sem parar o serviço |
| 2. Cópia de volume e bind | `tar` sobre o mountpoint do volume e sobre a pasta do host | Arquivo de usuário, certificado, e o próprio dado do banco em formato nativo |
| 3. Retrato do Docker | `docker inspect` de container, volume, rede, imagem e compose | Reconstruir a topologia e saber qual volume pertence a quem |

Camada 1 e camada 2 se cobrem. Se o dump lógico falhar por falta de ferramenta,
o volume ainda está lá. Se o volume vier inconsistente, o dump lógico restaura.
Para o caso em que nenhuma das duas serve sozinha (Mongo sem `mongodump`,
ClickHouse, Redis sem persistência ligada), entra o modo de parada curta.

### 4.2 Modos de execução

- `--modo auto` (padrão): nada para, exceto container de banco que não aceita
  dump lógico, e esse para pelo tempo da cópia do volume dele e volta. Melhor
  relação entre garantia e tempo fora do ar.
- `--modo quente`: nada para nunca. Para servidor que não pode piscar. O
  relatório marca cada banco que ficou só com cópia a quente.
- `--modo frio`: dumps primeiro, depois para tudo, copia, e religa exatamente o
  que estava de pé. Garantia máxima, com janela de indisponibilidade.

Decisão: usar `docker stop`, não `docker pause`. Pause congela o processo com
página suja em memória, então o arquivo em disco continua inconsistente. Stop
manda SIGTERM, o banco fecha limpo e grava tudo.

### 4.3 Segredo não passa pela linha de comando

Senha de banco vira script temporário com permissão 600 dentro do container, ou
arquivo `[client]` do MySQL no `/tmp` do container, apagado no fim. Nada de
`docker exec -e SENHA=...`, que aparece no `ps` do host. No Postgres a conexão
por socket local da imagem oficial usa `trust`, então nem precisa de senha.

### 4.4 Compressão em dois tempos

Cada artefato interno sai comprimido (nível 6, com `pigz` quando existe) e o
arquivo final empacota tudo com `gzip -1`. Comprimir duas vezes no nível alto
gastaria CPU para quase nada. Assim o pico de disco fica em torno de duas vezes
o tamanho já comprimido, em vez de uma vez o tamanho cru mais uma comprimida.

### 4.5 Religar o que foi parado, mesmo se o script morrer

A lista de containers parados vai para arquivo em disco antes de qualquer
parada, e um `trap` em EXIT, INT, TERM e ERR religa tudo. Se o processo morrer
de `kill -9`, o operador roda `--religar` e o script lê o arquivo e levanta de
volta. Backup que deixa o servidor no chão é pior que backup nenhum.

### 4.6 Deploy automático sem pedir token

Restaurar dados não basta: container de aplicação construída a partir de código
não existe na máquina nova. Exigir que o operador crie um token de API no painel
e rode o script outra vez quebra a promessa de um comando de cada lado.

A saída é criar o token nós mesmos, depois que o painel sobe. Quem cria é o
`createToken` do próprio Laravel, chamado dentro do container do painel, porque é
API estável do framework e cuida do formato e do hash. SQL feito à mão quebraria
na primeira mudança de schema. O token é usado e apagado no mesmo passo, e o
`trap` apaga também se a execução morrer antes.

Para a chamada de deploy usamos a API HTTP documentada, não as funções internas
do Coolify, que mudam entre versões. A prova de que funcionou é a própria API
responder autenticada, testada em mais de uma rota antes de confiar. Falhando
isso, o script apaga o token, avisa e deixa o deploy para o painel.

Só sobe o que estava no ar na origem, olhando o estado de cada container no
retrato do Docker. Subir tudo religaria recurso que o dono tinha desligado.

### 4.7 Google Drive com a chave do próprio rclone

O transporte é o rclone, o mesmo do DevBackup, porque ele resolve envio grande
com pedaço, repetição e conferência de soma.

O problema é a autorização: servidor não tem navegador, e o fluxo normal do
rclone abre o navegador na própria máquina.

O caminho padrão usa a chave que já vem embutida no rclone. O operador roda
`rclone authorize "drive"` no computador dele, o navegador abre, ele autoriza, e
o rclone imprime um token em uma linha, que ele cola no servidor. É o fluxo
headless documentado do rclone, sem a parte do assistente de perguntas.

Isso elimina a exigência de um projeto no Google Cloud. O Google passou a pedir
faturamento e verificação para aprovar app novo, e nem sempre aprova. O
estrangulamento dessa chave compartilhada é por taxa de requisição: dói em backup
de milhares de arquivos, como no DevBackup, e praticamente não aparece aqui, onde
sobe um tarball por execução.

Detalhe que decide se funciona: nesse caminho o `rclone.conf` sai **sem**
`client_id` e sem `client_secret`. É a ausência dessas linhas que faz o rclone
usar a chave embutida dele, inclusive para renovar o acesso. Gravar `client_id`
vazio quebraria a renovação em uma hora.

O caminho da chave própria continua disponível em `--drive-chave-propria`, para
quem quiser a cota maior. Ali o script monta o link de consentimento com
`redirect_uri` de localhost, o operador abre no computador dele, autoriza, e o
navegador cai numa página de erro cujo endereço contém o código. O operador cola
a URL inteira, o script tira o código e troca por token, com PKCE quando houver
openssl.

Nos dois casos o token vai para o `rclone.conf` escrito por nós, em vez de
`rclone config create`, porque a sintaxe desse comando mudou entre versões e o
formato do arquivo não. A seção existente é substituída preservando as outras,
com cópia de segurança antes.

Nada de segredo na linha de comando: código, chave e segredo viajam em arquivo
com permissão 600, lidos pelo `--data-urlencode name@arquivo` do curl, então não
aparecem no `ps` do servidor.

## 5. Não objetivos

- Não restaura sozinho em um comando. A restauração tem passo que depende de
  decisão humana (IP novo, DNS, versão do Coolify). Entregamos
  `restaurar-coolify.sh` com confirmação em cada etapa, e o `RESTAURAR.md`.
- Não sobe para S3 nem para outro servidor. O pedido é arquivo para download.
  O caminho do arquivo e o SHA256 saem no final para quem quiser enviar.
- Não cifra por padrão. O arquivo tem `APP_KEY`, senha de banco e chave SSH
  privada dentro. A flag `--cifrar` existe e o aviso sai sempre.
- Não exporta imagem Docker por padrão. Imagem se baixa de novo; `--imagens`
  existe para quem precisa restaurar sem internet.

## 6. Validação

| O que | Como |
|---|---|
| Sintaxe | `bash -n backup-coolify.sh` e `bash -n restaurar-coolify.sh` |
| Lógica de shell | `shellcheck` sem erro de nível error |
| Simulação | `--simular` lista fonte, tamanho e estimativa sem escrever nada |
| Integridade do pacote | `gzip -t` e `tar -tzf` dentro do próprio script, antes de declarar pronto |
| Conferência por item | `CHECKSUMS.sha256` com SHA256 de cada artefato interno |
| Restauração | `restaurar-coolify.sh --conferir` lê o pacote e diz o que falta antes de tocar no servidor |

## 6.1 Defeitos que só apareceram no teste

Vale registrar, porque todos passariam calados em revisão de leitura:

1. O teste de suporte a ACL e xattr do `tar` na restauração usava
   `tar -tf /dev/null`, que nunca passa porque `/dev/null` não é um tar válido.
   A restauração perderia ACL e xattr sem avisar. Agora o teste é feito no modo
   de criação, que depende dos mesmos recursos de compilação.
2. O proxy do Coolify tem compose próprio, fora de `/data/coolify/source`. A
   restauração parava todos os containers e subia só a pilha do painel, então o
   servidor voltava sem proxy e nenhum domínio respondia.
3. `[[ -r /dev/tty ]]` responde que existe terminal mesmo quando o processo não
   tem terminal de controle, como no cron. A autorização do Drive imprimia erro
   de dispositivo em vez da instrução. O teste honesto é tentar abrir.
4. Algumas builds do openssl terminam a saída com retorno de carro. Esse byte
   dentro do verificador PKCE faria o Google responder `invalid_grant` sem
   explicar o motivo.
5. O volume do banco do painel era procurado pelo nome fixo `coolify-db`. O nome
   depende de como o compose daquela versão nomeia o volume, então agora ele é
   lido do container durante o backup e gravado no manifesto.
6. `grep -c` imprime zero e sai com código 1 quando não acha nada, então
   `$(grep -c . arquivo || echo 0)` devolvia a string "0
0". Trocado por awk.

## 7. Riscos aceitos

- Volume com driver diferente de `local` cai no caminho do container ajudante,
  que usa `tar` do BusyBox e não leva ACL nem xattr. O relatório avisa.
- `--modo quente` em banco sem ferramenta de dump entrega cópia a quente. O
  relatório marca como risco, com nome do container.
- Estimativa de espaço usa `du`, que demora em disco grande e conta bloco, não
  tamanho aparente. Serve para evitar o erro de disco cheio, não para prever o
  tamanho final com exatidão.

## 8. Fontes

- Coolify, backup de instância: https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify
- Coolify, restauração de instância: https://coolify.io/docs/core/backup-and-recovery/instance-restore
- Coolify, modelo de segurança e cifra com APP_KEY: https://coolify.io/docs/core/security-model
- Coolify, bancos gerenciados e volume nomeado: https://coolify.io/docs/databases
- MongoDB Database Tools fora da imagem do servidor: https://www.mongodb.com/docs/database-tools/mongodump/mongodump-compatibility-and-installation/
- Backup de volume Docker e consistência: https://www.augmentedmind.de/2023/08/20/backup-docker-volumes/
