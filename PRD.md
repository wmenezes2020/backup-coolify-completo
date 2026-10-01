# PRD: Backup e restauração total de servidor Coolify

Versão 1.0.0 | 01/10/2026 | Grupo Life Company

## 1. Para que serve

Levantar um servidor Coolify inteiro em outra máquina, sem perda de dados, com
dois comandos: um que gera um arquivo único e outro que restaura a partir dele.

O público é quem administra o servidor. Não tem interface, roda no terminal, e
toda saída é feita para ser lida por quem está com o servidor na mão.

## 2. Problema que resolve

O backup nativo do Coolify cobre apenas o banco interno do painel. A própria
documentação diz que ele não inclui dados de aplicação, bancos e volumes.
Restaurar só esse backup devolve um painel que lista projetos cujos dados não
existem mais. Além disso, a `APP_KEY` que decifra todos os segredos guardados no
banco fica fora do dump, então um painel restaurado sem ela abre e não consegue
ler nenhuma credencial.

## 3. Entregas

### 3.1 `backup-coolify.sh`

| Requisito | Detalhe | Aceite |
|---|---|---|
| Arquivo único | Um `.tar.gz` no fim, com tudo dentro | o arquivo existe, passa em `gzip -t` e em `tar -tzf` |
| Dump lógico por banco | Postgres, MySQL, MariaDB, MongoDB, Redis e família, ClickHouse | `02-bancos/_bancos.tsv` registra container, motor, método e situação |
| Volumes Docker | Todos os volumes da máquina, não só os de containers de pé | `03-volumes/_lista.tsv` tem uma linha por volume |
| Pastas de host | Todo bind montado em container, fora de `/data/coolify` | `04-binds/_mapa.tsv` mapeia caminho original e arquivo |
| `/data/coolify` | Pasta inteira, incluindo `source`, `ssh`, `applications`, `services`, `proxy` | `01-coolify/data-coolify.tar.gz` presente |
| APP_KEY isolada | Fora do `.env`, em arquivo próprio | `01-coolify/APP_KEY.txt` com a linha `APP_KEY=` |
| Chaves públicas | Derivadas das privadas, para o `authorized_keys` do destino | `01-coolify/chaves-publicas.txt` |
| Retrato do Docker | Containers, volumes, redes, imagens, compose, versão do Coolify | `00-meta/` com os `.tsv` e `info.txt` |
| Sistema | `daemon.json`, crontab, `authorized_keys`, firewall, pacotes, rede | `05-sistema/` |
| Três modos | `auto`, `quente`, `frio` | `info.txt` grava o modo usado |
| Religamento garantido | Nada fica parado por falha do script | `trap` em EXIT, INT, TERM e ERR, mais `--religar` |
| Conferência | SHA256 do pacote e de cada arquivo interno | `.sha256` ao lado e `CHECKSUMS.sha256` dentro |
| Roteiro | Passo a passo com os valores reais daquele servidor | `RESTAURAR.md` |
| Relatório honesto | Falha e aviso aparecem no fim e no manifesto | saída lista avisos e falhas, código de saída 2 se houve falha |
| Cifra opcional | AES256 por gpg, openssl como reserva | `--cifrar` gera `.tar.gz.gpg` |
| Envio ao Google Drive | Opcional por flag, transporte rclone, autorização por link colado de volta | `--google-drive` entrega o pacote e confere o tamanho no destino |
| Autorização sem navegador no servidor | Padrão: usa a chave embutida no rclone, operador roda `rclone authorize "drive"` na máquina dele e cola o token | `--drive-configurar` grava o remote sem `client_id` e o teste de conexão passa |
| Caminho alternativo com chave própria | Cinco telas do Google Cloud, link gerado e URL de retorno colada | `--drive-chave-propria` grava `client_id` e `client_secret` no remote |
| Retenção no Drive | Guarda os N mais novos na pasta | `--drive-manter N` remove só arquivo do padrão de nome do script |
| Simulação | Mostra fonte, tamanho e estimativa sem gravar | `--simular` |

### 3.2 `restaurar-coolify.sh`

| Requisito | Detalhe | Aceite |
|---|---|---|
| Um comando | `--arquivo pacote.tar.gz` restaura tudo | painel abre com os projetos, bancos de pé, arquivos no lugar |
| Validação antes | SHA256, `gzip -t`, somas internas | recusa pacote corrompido antes de tocar no servidor |
| Instalação da versão certa | Instala o Coolify na versão da origem se faltar | lê `versao_coolify` do manifesto |
| Clone completo | Volume do banco do painel mais `.env` original | sem decifragem e sem `pg_restore` quando o volume veio no pacote |
| Caminho por dump | `pg_restore` quando o volume não veio, ou com `--via-dump` | APP_KEY gravada no `.env` do instalador |
| Redes | Recria com driver, faixa, etiquetas; cai para faixa automática em conflito | avisa quando a faixa original não cabe |
| Volumes | Recria com driver e etiquetas, devolve o conteúdo | relatório diz quantos voltaram e quantos falharam |
| Pastas de host | Devolve no caminho original | relatório conta as devolvidas |
| Chaves SSH | Publica as públicas do Coolify no `authorized_keys` | Servers > localhost valida no painel |
| Imagens | Carrega as do pacote quando existem | permite restauração sem internet |
| Sobe o proxy | Compose próprio do proxy, fora do compose do painel | proxy de pé no fim, ou falha explícita com o caminho do painel |
| Sobe recursos | Compose em disco, e deploy automático pela API | relatório separa na fila, recusado e pulado |
| Deploy sem token manual | Cria token de uso único no painel, usa e apaga | a linha criada em `personal_access_tokens` não fica para trás |
| Respeita o estado da origem | Só sobe recurso que tinha container rodando no backup | recurso parado na origem aparece como pulado |
| Proteção | Exige a palavra `RESTAURAR` se a máquina já tem Coolify com dados | não atropela servidor em uso por acidente |
| Conferência seca | `--conferir` lê o pacote e não altera nada | sai com o plano e o caminho do `RESTAURAR.md` |
| Preservação de atributos | Dono numérico, ACL e xattr | teste de suporte do `tar` feito no modo de criação |

## 4. Fora de escopo

- Envio para S3 ou outro servidor. O pedido é arquivo para download. Caminho e
  SHA256 saem no fim para quem quiser enviar.
- Retenção e rotação de pacotes antigos. Apagar backup é decisão de quem opera.
- Interface gráfica ou painel.
- Migração entre arquiteturas diferentes sem novo deploy. Imagem de `x86_64` não
  roda em `aarch64`, e o script avisa quando detecta a troca.
- Cifra por padrão. Fica em `--cifrar`, com aviso em toda execução.

## 5. Decisões de produto e o porquê

**Modo `auto` como padrão.** Parar o servidor inteiro a cada backup é caro e
quase nunca necessário, porque dump lógico já sai consistente. A parada curta
fica só onde não existe ferramenta de dump na imagem.

**Clone completo como caminho principal da restauração.** Trazer o volume do
banco do painel junto com o `.env` original faz APP_KEY, senha e dados baterem
entre si, sem passo manual. O dump lógico continua no pacote e entra sozinho
quando o volume não está lá, ou quando a versão maior do Postgres mudou.

**Sobrescrever volume por padrão na restauração.** Restaurar é trocar. O plano
diz antes quantos volumes com conteúdo serão substituídos, e `--nao-sobrescrever`
existe para quem quer preservar.

**Segredo em base64 nos scripts gerados.** Senha de banco viaja codificada para
dentro do container, nunca na linha de comando. Elimina a classe de erro de aspas
dentro de aspas e não aparece no `ps` do host.

**Chave do rclone como padrão no Google Drive.** O estrangulamento que o Google
aplica na chave compartilhada do rclone é por taxa de requisição, e dói em backup
de milhares de arquivos. Aqui sobe um tarball por execução, então o limite
praticamente não aparece. Exigir uma chave própria custaria um projeto no Google
Cloud com faturamento e verificação, que o Google nem sempre aprova. A chave
própria fica em `--drive-chave-propria`, para quem quiser a cota maior.

**Não apagar nada por conta própria.** O script não remove pacote antigo, não
roda `git clean`, não mexe em histórico. Limpeza é pedido explícito.

## 6. Validação feita nesta entrega

| O que | Resultado |
|---|---|
| `bash -n` nos dois scripts | sem erro |
| Execução completa com Docker simulado (5 containers, 5 volumes, 1 bind, 4 motores de banco) | pacote gerado, `gzip -t` e `tar -tzf` passaram |
| Caminho de parada curta no Mongo sem `mongodump` | container parado, volume copiado, container religado |
| Ida e volta de dados: apagar tudo e restaurar | 15 de 15 arquivos com SHA256 idêntico ao original |
| Caminho `--via-dump` | `.env` manteve a senha do instalador e recebeu a APP_KEY da origem |
| `--conferir` | validou somas e saiu sem alterar o servidor |
| Senha com aspa, cifrão, crase e barra invertida | chegou intacta dentro do container |
| Deploy automático com API simulada | token criado, 2 recursos na fila, 1 pulado por estar parado na origem, token apagado |
| Rota por tipo de recurso | serviço foi por `/api/v1/deploy`, banco foi por `/api/v1/databases/<uuid>/start` |
| Envio ao Google Drive com rclone simulado | arquivo no destino byte a byte igual ao local, tamanho conferido |
| Leitura do token colado | aceita o bloco inteiro do `rclone authorize`, só a linha do JSON, com espaços em volta, e recusa token sem `refresh_token` |
| Escrita do `rclone.conf` | caminho padrão sai sem `client_id`, caminho de chave própria sai com os dois, e o remote de outro serviço no mesmo arquivo sobrevive |
| Retenção no Drive | `--drive-manter 2` guardou os 2 mais novos e removeu 3 antigos |
| Autorização sem terminal | recusou com instrução clara, sem travar esperando entrada |
| Rodada completa com proxy e Drive | 18 de 18 arquivos idênticos depois de apagar e restaurar |

## 7. Próximos passos sugeridos

1. Agendar no cron e guardar uma cópia fora do servidor.
2. Exercício de restauração em máquina descartável, uma vez por trimestre.
   Backup que nunca foi restaurado é hipótese, não garantia.
3. Alerta no monitoramento para código de saída diferente de zero.
4. Avaliar `--imagens` para os projetos construídos a partir de código, se o
   objetivo for restaurar sem depender de internet nem de rebuild.
