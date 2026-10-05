# Backup e restauração total de servidor Coolify

Dois scripts. Um gera um arquivo `.tar.gz` com o servidor inteiro dentro. O outro
levanta esse servidor em outra máquina.

No servidor atual, para gerar o backup:

```bash
chmod +x backup-coolify.sh && sudo ./backup-coolify.sh
```

No servidor novo, para restaurar:

```bash
chmod +x restaurar-coolify.sh && sudo ./restaurar-coolify.sh --arquivo coolify-backup-SERVIDOR-DATA.tar.gz
```

A restauração devolve dados, painel e registros, e ainda sobe de volta ao ar todo
recurso que estava rodando na origem. Você não precisa clicar em Deploy.

Para o backup subir sozinho para o Google Drive, acrescente `--google-drive`.
Na primeira vez o script mostra um link: você abre no navegador, clica em
Permitir, copia o endereço em que o navegador caiu e cola de volta. Nada para
instalar na sua máquina, e nada para criar no Google Cloud.

## Instalação

**1. Copie os dois arquivos para o servidor**

```bash
scp backup-coolify.sh restaurar-coolify.sh root@SEU_SERVIDOR:/root/
```

**2. Dê permissão de execução**

Entre no servidor por SSH e rode:

```bash
chmod +x /root/backup-coolify.sh /root/restaurar-coolify.sh
```

Sem isso o shell responde `Permission denied`, porque arquivo copiado por `scp`,
baixado do navegador ou saído do Windows chega sem o bit de execução. Para
conferir que pegou, os dois têm que aparecer com `x` na listagem:

```bash
ls -l /root/*.sh
```

Se por algum motivo não quiser mexer na permissão, dá para rodar chamando o
interpretador na mão, que funciona igual:

```bash
sudo bash /root/backup-coolify.sh
```

**3. Rode como root**

O backup lê `/var/lib/docker/volumes` e `/data/coolify/ssh`, e a restauração
escreve nos dois. Sem root, nenhum dos dois tem como funcionar, e os scripts
param na primeira checagem avisando isso.

## O que entra no pacote

| Pasta | Conteúdo |
|---|---|
| `00-meta/` | retrato do Docker: containers, volumes, redes, imagens, compose, versão do Coolify |
| `01-coolify/` | `/data/coolify` inteiro, mais a `APP_KEY` isolada e as chaves públicas derivadas |
| `02-bancos/` | dump lógico de cada banco, feito pela ferramenta do próprio banco |
| `03-volumes/` | um arquivo por volume Docker da máquina |
| `04-binds/` | cada pasta de host montada dentro de algum container |
| `05-sistema/` | `daemon.json`, crontab, `authorized_keys`, firewall, pacotes, rede |
| `06-imagens/` | imagens Docker, só com `--imagens` |
| `RESTAURAR.md` | roteiro gerado com os valores reais daquele servidor |
| `CHECKSUMS.sha256` | SHA256 de cada arquivo interno, para conferir item por item |

## Por que três camadas em vez de uma

O backup não aposta em uma técnica só, porque cada uma falha de um jeito diferente.

**Dump lógico.** `pg_dumpall`, `mysqldump --single-transaction`, `mongodump`. Sai
consistente com o serviço no ar, porque quem tira o retrato é o próprio banco.

**Cópia de volume e de bind.** Pega o que nenhum dump pega: arquivo enviado por
usuário, certificado, fila de e-mail, configuração montada de fora.

**Retrato do Docker.** Diz qual volume pertence a quem, quais redes existiam e em
que versão o Coolify estava. Sem isso a restauração é adivinhação.

Onde nenhuma das duas primeiras resolve sozinha, o script para aquele container
pelos segundos da cópia e religa. Vale para Mongo sem `mongodump` na imagem,
ClickHouse e Dragonfly.

## Os três modos

| Modo | O que para | Quando usar |
|---|---|---|
| `--modo auto` (padrão) | só banco sem ferramenta de dump, pelo tempo da cópia | dia a dia |
| `--modo quente` | nada | servidor que não pode piscar |
| `--modo frio` | tudo, depois dos dumps, e religa igual | antes de migrar, garantia máxima |

Usa `docker stop`, não `docker pause`. Pause congela o processo com página suja
na memória, então o arquivo em disco continua pela metade. Stop manda SIGTERM, o
banco fecha limpo e grava tudo.

## A APP_KEY é o item que faz ou quebra a restauração

O Coolify cifra senha, token e chave privada antes de gravar no banco. A chave
dessa cifra é a `APP_KEY` de `/data/coolify/source/.env`, e ela **não entra no
dump do banco**. Restaurar o banco com outra APP_KEY devolve um painel que abre,
lista os projetos e não consegue ler nenhum segredo: servidor não valida, deploy
não roda, integração não autentica.

Os dois scripts tratam isso como item de primeira classe. O backup guarda a chave
isolada em `01-coolify/APP_KEY.txt`, e a restauração grava ela no `.env` do
servidor novo antes de subir o painel.

## Como a restauração funciona

O caminho padrão é clone completo. O volume do banco do painel volta junto com o
`.env` original, então APP_KEY, senha de banco e dados batem entre si e nada
precisa ser decifrado de novo. O dump lógico fica como rede de segurança e entra
em cena sozinho se o volume não estiver no pacote.

Ordem das etapas:

1. confere SHA256 do pacote, testa o gzip, abre e confere as somas internas
2. instala o Coolify na mesma versão da origem, se ele ainda não estiver lá
3. para os containers
4. devolve `/data/coolify`
5. recria as redes Docker com driver, faixa e etiquetas originais
6. devolve todos os volumes
7. devolve as pastas de host
8. carrega as imagens, se vieram no pacote
9. publica as chaves do Coolify no `authorized_keys` do root
10. sobe a pilha do painel e espera o banco responder
11. sobe o proxy, que tem compose próprio e não vem no compose do painel
12. sobe os recursos que têm compose em disco
13. dispara o deploy de todo recurso que estava de pé na origem, com um token de
    uso único que ele cria e apaga

Antes de tocar em qualquer coisa ele mostra o plano e pede confirmação. Se achar
um Coolify com aplicações cadastradas naquela máquina, exige que você escreva
`RESTAURAR` para seguir.

## Conferir sem mexer no servidor

```bash
sudo ./restaurar-coolify.sh --arquivo pacote.tar.gz --conferir
```

Abre o pacote, valida as somas, mostra o que tem dentro e sai. Não escreve nada.

## O detalhe das chaves SSH que derruba restauração

O instalador do Coolify cria um par de chaves novo e coloca a pública no
`authorized_keys` do root. Ao restaurar o banco, o painel volta apontando para a
chave **antiga**, que não está mais autorizada. Resultado: Servers > localhost
falha ao validar e nenhum deploy sai.

O script resolve isso: deriva a chave pública de cada chave privada em
`/data/coolify/ssh/keys`, junta com o `authorized_keys` que veio do pacote,
remove repetidas e grava.

## Os recursos voltam ao ar sozinhos

Container de aplicação construída a partir de código não existe na máquina nova,
porque a imagem dela foi montada no servidor antigo. Quem recria isso é o deploy.

A restauração faz esse deploy por você, sem pedir nada. Para isso ela cria um
token de uso único dentro do próprio painel que acabou de subir, dispara o deploy
de cada recurso e apaga o token no fim. Nada fica para trás, nem se a execução
morrer no meio.

**Ela só sobe o que estava no ar na origem.** O backup guarda o estado de cada
container, então recurso que você tinha deixado parado continua parado. Banco de
dados usa a rota própria de start do Coolify; aplicação e serviço usam a de
deploy.

| Opção | Para que serve |
|---|---|
| nenhuma | o padrão: deploy automático do que estava de pé |
| `--sem-deploy` | não dispara deploy nenhum, você clica no painel |
| `--api-token T` | usa um token seu em vez de criar um temporário |

Se a API recusar o token, o script avisa, lista os recursos que ficaram de fora e
segue. Nenhum dado se perde nisso: banco, volume, arquivo de usuário, certificado
e registro do painel já voltaram antes dessa etapa.

Uma coisa continua valendo a pena: rodar o backup com `--imagens` quando você
quer restaurar sem depender de internet nem de rebuild. Aí a imagem viaja no
pacote e o deploy só a reaproveita.

## Enviar o backup para o Google Drive

Opcional, ativado por flag, e usa o mesmo transporte do DevBackup: o rclone. Não
precisa de projeto no Google Cloud, nem de faturamento, nem de aprovação de app.

**A primeira vez, uma vez só:**

```bash
sudo ./backup-coolify.sh --drive-configurar
```

Um link e uma colada. Nada para instalar na sua máquina.

1. O script imprime um link. Você copia e abre no navegador do seu computador.
2. Escolhe a conta Google onde o backup vai ficar e clica em **Permitir**.
3. A página seguinte vai dizer que não conseguiu acessar `127.0.0.1`. É isso
   mesmo, não deu errado: **o endereço dela é a sua resposta.**
4. Você copia a barra de endereço inteira e cola no terminal. Acabou.

O script tira o código daquela URL, troca por um token no Google e grava no
`rclone.conf`. Se preferir, dá para colar só o pedaço depois de `code=`.

### Por que a página dá erro, e por que não dá para ser diferente

O OAuth do Google exige um endereço de retorno em todo pedido de autorização.
Como o servidor não tem navegador, esse endereço aponta para `127.0.0.1`, que é
a sua própria máquina, onde não há nada escutando. Daí a página de erro. O
código que importa já veio junto, no endereço.

As duas alternativas que mostrariam o código na tela não existem mais:

- o modo em que o Google exibia o código com um botão de copiar foi desligado
  por ele em 2022, e hoje responde `Error 400: invalid_request`;
- o modo de aparelho sem teclado, em que você digitaria um código curto em
  `google.com/device`, não aceita o escopo do Drive.

**Daí em diante:**

```bash
sudo ./backup-coolify.sh --google-drive
```

Fecha o pacote, envia, confere o tamanho no Drive e termina. Sem interação, o que
serve para o cron.

### Por que a chave do rclone serve bem aqui

O rclone vem com uma chave de acesso ao Google compartilhada por todos os
usuários dele, e o Google estrangula essa chave. O DevBackup mediu cerca de 25
arquivos por minuto, o que inviabiliza um backup de 13 mil arquivos.

Aqui o caso é outro: sobe **um** tarball por execução. São poucas requisições, e
o limite por taxa praticamente não aparece. É por isso que este script usa a
chave do rclone por padrão, em vez de exigir que você crie a sua.

Se um dia você quiser a cota maior e conseguir criar o projeto no Google Cloud,
existe o caminho alternativo:

```bash
sudo ./backup-coolify.sh --drive-configurar --drive-chave-propria
```

Aí o script abre as 5 telas do Google Cloud, pede os dois códigos, gera o link de
autorização e você cola a URL de retorno. Vale avisar que o Google passou a
exigir faturamento e verificação em muitos casos, e nem sempre aprova.

### Opções do Drive

| Opção | Para que serve |
|---|---|
| `--google-drive` | envia o pacote ao Drive no fim do backup |
| `--drive-configurar` | só faz a autorização e sai |
| `--drive-chave-propria` | usa chave sua do Google Cloud em vez da do rclone |
| `--drive-reconfigurar` | refaz a autorização mesmo havendo uma |
| `--drive-pasta P` | pasta no Drive. Padrão `BackupCoolify/NOME_DA_MAQUINA` |
| `--drive-remote N` | nome do remote no rclone. Padrão `coolify-drive` |
| `--drive-escopo E` | `total` (padrão) ou `arquivos`, que limita o acesso ao que o script cria |
| `--drive-manter N` | guarda os N pacotes mais novos na pasta e remove os antigos |

Escolhendo `--drive-escopo arquivos`, o link que o script mostra já sai com o
escopo reduzido. Você não muda nada.

### Segurança

O script nunca manda senha ou token pela linha de comando. No caminho da chave
própria, código, id e segredo viajam em arquivo com permissão 600 lidos pelo
`--data-urlencode name@arquivo` do curl, então não aparecem no `ps` do servidor.
O token fica no `rclone.conf`, também 600, e o rclone renova o acesso sozinho.

Quando a chave é a do rclone, o `rclone.conf` sai **sem** `client_id`. Isso é de
propósito: é o que faz o rclone usar a chave embutida dele também na renovação.

### Trazer o pacote de volta do Drive

No servidor novo:

```bash
rclone copy coolify-drive:BackupCoolify/NOME_DA_MAQUINA /var/backups/coolify --include "*.tar.gz*" --progress
```

Se o servidor novo ainda não tem o rclone configurado, rode nele
`./backup-coolify.sh --drive-configurar` primeiro, que é a mesma autorização.

## Qual opção é de qual script

| Opção | Backup | Restauração |
|---|---|---|
| `--destino`, `--modo`, `--imagens`, `--sem-backups`, `--compressao`, `--simular`, `--forcar`, `--religar` | sim | não |
| `--google-drive`, `--drive-configurar`, `--drive-chave-propria`, `--drive-reconfigurar`, `--drive-pasta`, `--drive-remote`, `--drive-escopo`, `--drive-manter` | sim | não |
| `--arquivo`, `--pasta`, `--conferir`, `--versao`, `--sem-instalar`, `--nao-sobrescrever`, `--nao-subir`, `--sem-deploy`, `--sistema`, `--via-dump`, `--dumps-bancos`, `--temp`, `--api-token`, `--api-url` | não | sim |
| `--cifrar`, `--senha-arquivo` | cifra o pacote | decifra o pacote |
| `--sim`, `--ajuda` | sim | sim |

## Segurança do arquivo

O pacote tem `APP_KEY`, senha de todo banco e chave SSH privada dentro. É um
arquivo que abre seu servidor. Guarde como segredo.

Para levar para fora do servidor, cifre:

```bash
sudo ./backup-coolify.sh --cifrar
```

Gera `.tar.gz.gpg` com AES256. A restauração aceita o arquivo cifrado direto e
pede a senha.

## Agendar

```bash
0 3 * * * /root/backup-coolify.sh -d /var/backups/coolify --sem-backups --google-drive --drive-manter 7 >> /var/log/backup-coolify.log 2>&1
```

Esse exemplo manda para o Drive e guarda os sete pacotes mais novos lá. Antes de
agendar, rode `./backup-coolify.sh --drive-configurar` uma vez na mão: a
autorização precisa de terminal, e depois dela o envio roda sozinho. Se o cron
rodar sem a autorização feita, o script falha com essa mensagem em vez de travar
esperando resposta.

O script sai com código 2 se alguma etapa falhou, então o monitoramento percebe.
Vale manter o pacote fora do servidor também: disco que morre leva o backup que
mora nele.

## Se a execução for interrompida no meio

O script anota em disco cada container que parou e religa tudo no `trap`. Se o
processo morrer de um jeito que não dá chance ao `trap`, como `kill -9` ou queda
de energia:

```bash
sudo ./backup-coolify.sh --religar
```

Ele lê a anotação e levanta de volta o que ficou parado.

## Ajuda completa

```bash
./backup-coolify.sh --ajuda
```

```bash
./restaurar-coolify.sh --ajuda
```

## Documentos

- [SDD](docs/SDD_BACKUP_COOLIFY.md): problema, causas raiz, decisões de projeto e validação
- [PRD](PRD.md): o que o produto faz, requisitos e critérios de aceite

## Fontes consultadas

- [Coolify, backup de instância](https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify)
- [Coolify, restauração de instância](https://coolify.io/docs/core/backup-and-recovery/instance-restore)
- [Coolify, modelo de segurança](https://coolify.io/docs/core/security-model)
- [Coolify, bancos gerenciados](https://coolify.io/docs/databases)
- [Coolify, API de deploy](https://coolify.io/docs/api-reference/api/operations/deploy-by-tag-or-uuid)
- [MongoDB Database Tools fora da imagem do servidor](https://www.mongodb.com/docs/database-tools/mongodump/mongodump-compatibility-and-installation/)
- [Consistência em backup de volume Docker](https://www.augmentedmind.de/2023/08/20/backup-docker-volumes/)
