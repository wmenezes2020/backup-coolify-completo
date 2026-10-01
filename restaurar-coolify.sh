#!/usr/bin/env bash
#
# restaurar-coolify.sh
# Restaura, em um servidor Linux, o pacote gerado por backup-coolify.sh.
#
# Devolve, nesta ordem: Coolify na mesma versao da origem, /data/coolify inteiro
# (com a APP_KEY original), redes Docker, todos os volumes, as pastas de host
# montadas em containers, as imagens (se vieram no pacote), as chaves SSH no
# authorized_keys, a pilha do painel, e os recursos que tem compose em disco.
#
# Uso:  sudo ./restaurar-coolify.sh --arquivo coolify-backup-*.tar.gz
# Ajuda: ./restaurar-coolify.sh --ajuda

set -Eeuo pipefail

VERSAO_SCRIPT="1.0.0"
NOME_SCRIPT="$(basename "$0")"

# ---------------------------------------------------------------------------
# Opcoes
# ---------------------------------------------------------------------------
ARQUIVO=""
PASTA=""
SO_CONFERIR=0
SEM_INSTALAR=0
VERSAO_FORCADA=""
SOBRESCREVER=1          # restaurar e, por definicao, trocar o que esta aqui
NAO_SUBIR=0
SEM_DEPLOY=0
RESTAURA_SISTEMA=0
VIA_DUMP=0
DUMPS_BANCOS=0
ARQUIVO_SENHA=""
TEMP_PEDIDO=""
SIM=0
API_TOKEN=""
API_URL=""
DIR_DADOS_COOLIFY="/data/coolify"
IMAGEM_AJUDANTE="alpine:3.20"

# ---------------------------------------------------------------------------
# Estado
# ---------------------------------------------------------------------------
INICIO_EPOCH="$(date +%s)"
CARIMBO="$(date +%Y%m%d-%H%M%S)"
NOME_TOKEN="restauracao-automatica-$CARIMBO"
TOKEN_FOI_CRIADO=0
PACOTE=""                 # pasta aberta do pacote
TEMP=""                   # pasta temporaria nossa
LOG="/var/log/restaurar-coolify-$CARIMBO.log"
COMPOSE=""
declare -a AVISOS=()
declare -a ERROS=()
declare -a FLAGS_EXTRACAO=()
declare -a SUBIRAM=()
declare -a NAO_SUBIRAM=()
CORES=0
TEM_VOLUME_COOLIFY_DB=0

cor() { if ((CORES)); then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
agora() { date '+%H:%M:%S'; }
diz()   { printf '%s %s\n' "$(cor '0;90' "[$(agora)]")" "$*"; }
passo() { printf '\n%s %s\n' "$(cor '1;36' '==>')" "$(cor '1' "$*")"; }
feito() { printf '%s %s\n' "$(cor '0;32' '  ok')" "$*"; }
aviso() { AVISOS+=("$*"); printf '%s %s\n' "$(cor '1;33' '  !!')" "$*"; }
falha() { ERROS+=("$*");  printf '%s %s\n' "$(cor '1;31' '  xx')" "$*"; }
morre() { printf '\n%s %s\n' "$(cor '1;31' 'ERRO:')" "$*" >&2; exit 1; }
[[ -t 1 ]] && CORES=1

ajuda() {
  cat <<AJUDA
$NOME_SCRIPT v$VERSAO_SCRIPT

Restaura em um servidor Linux o pacote gerado pelo backup-coolify.sh. Um comando
devolve painel, registros, bancos de dados, volumes e arquivos.

USO
  sudo ./$NOME_SCRIPT --arquivo coolify-backup-SERVIDOR-DATA.tar.gz

OPCOES
  -a, --arquivo F     Pacote .tar.gz (ou .gpg / .enc, que sera decifrado)
      --pasta DIR     Usa um pacote ja aberto em DIR, em vez de um .tar.gz
      --conferir       Abre o pacote, confere as somas e mostra o plano.
                       Nao toca em nada no servidor.
      --versao V      Instala esta versao do Coolify em vez da versao da origem
      --sem-instalar  Nao roda o instalador do Coolify (exige Docker pronto)
      --nao-sobrescrever  Preserva volume que ja existe com conteudo nesta
                      maquina, em vez de trocar pelo do pacote. Por padrao o
                      pacote manda, porque restaurar e trocar.
      --nao-subir     Nao sobe os recursos pelos compose em disco
      --sem-deploy    Nao dispara deploy nenhum no fim. Por padrao o script
                      traz de volta ao ar todo recurso que estava de pe na
                      origem, criando um token de uso unico no painel e
                      apagando ele depois. Recurso que estava parado na origem
                      continua parado.
      --sistema       Tambem devolve daemon.json, crontab e authorized_keys
      --via-dump      Restaura o banco interno do Coolify pelo dump em vez de
                      usar o volume do coolify-db que veio no pacote
      --dumps-bancos  Depois dos volumes, reaplica tambem o dump logico de cada
                      banco de aplicacao. Use em migracao entre versoes de motor.
      --senha-arquivo F  Senha para decifrar um pacote .gpg ou .enc
      --temp DIR      Pasta de trabalho para abrir o pacote. Por padrao o script
                      escolhe entre /var/tmp, /tmp e a pasta do pacote a que
                      tiver mais espaco livre.
      --api-token T   Token da API do Coolify. Com ele o script manda deploy de
                      todos os recursos no fim, sem voce clicar um por um.
                      Esta opcao e so deste script; o backup-coolify.sh nao usa
                      a API. O token nasce no painel, em Keys & Tokens. Crie no
                      servidor antigo antes do backup e ele continua valendo
                      aqui, porque viaja dentro do banco restaurado. Sem token
                      nada se perde: restaure, crie o token no painel que subiu
                      e rode de novo com --api-token --nao-subir -s
      --api-url U     Base da API, para o caso do painel nao responder em
                      localhost. Padrao: http://localhost:PORTA_DO_PAINEL
  -s, --sim           Responde sim a todas as perguntas (uso automatizado)
  -h, --ajuda         Esta ajuda

COMO A RESTAURACAO FUNCIONA
  O caminho padrao e o clone completo: o volume do banco interno do Coolify vem
  do pacote junto com o .env original, entao APP_KEY, senha do banco e dados
  batem entre si e nada precisa ser decifrado de novo. O dump logico fica como
  rede de seguranca e e usado automaticamente se o volume nao estiver no pacote.

DEPOIS DE RODAR
  Recurso que tem compose em disco sobe sozinho. Aplicacao construida a partir
  de codigo precisa de um deploy para a imagem ser montada na maquina nova, a
  nao ser que o backup tenha sido feito com --imagens. Com --api-token o script
  dispara esses deploys por voce.
AJUDA
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while (($#)); do
  case "$1" in
    -a|--arquivo)     ARQUIVO="${2:?arquivo}"; shift 2 ;;
    --pasta)          PASTA="${2:?pasta}"; shift 2 ;;
    --conferir)       SO_CONFERIR=1; shift ;;
    --versao)         VERSAO_FORCADA="${2:?versao}"; shift 2 ;;
    --sem-instalar)   SEM_INSTALAR=1; shift ;;
    --sobrescrever)   SOBRESCREVER=1; shift ;;
    --nao-sobrescrever) SOBRESCREVER=0; shift ;;
    --nao-subir)      NAO_SUBIR=1; shift ;;
    --sem-deploy)     SEM_DEPLOY=1; shift ;;
    --sistema)        RESTAURA_SISTEMA=1; shift ;;
    --via-dump)       VIA_DUMP=1; shift ;;
    --dumps-bancos)   DUMPS_BANCOS=1; shift ;;
    --senha-arquivo)  ARQUIVO_SENHA="${2:?arquivo}"; shift 2 ;;
    --temp)           TEMP_PEDIDO="${2:?pasta}"; shift 2 ;;
    --api-token)      API_TOKEN="${2:?token}"; shift 2 ;;
    --api-url)        API_URL="${2:?url}"; shift 2 ;;
    -s|--sim)         SIM=1; shift ;;
    -h|--ajuda|--help) ajuda; exit 0 ;;
    *) morre "opcao desconhecida: $1 (use --ajuda)" ;;
  esac
done

[[ -n "$ARQUIVO" || -n "$PASTA" ]] || { ajuda; echo; morre "informe --arquivo ou --pasta"; }

# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
tem() { command -v "$1" >/dev/null 2>&1; }

conta() {  # linhas nao vazias de um arquivo, 0 se nao existir
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk 'NF{n++} END{print n+0}' "$1" 2>/dev/null || echo 0
}

legivel() {
  awk -v b="${1:-0}" 'BEGIN{ s="B KB MB GB TB PB"; split(s,u," "); i=1;
    while (b>=1024 && i<6) { b/=1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

pergunta() {  # pergunta "texto" -> 0 para sim
  ((SIM)) && return 0
  local r=""
  printf '\n%s %s [s/N] ' "$(cor '1;33' '???')" "$1"
  read -r r </dev/tty || true
  [[ "$r" == [sS]* || "$r" == [yY]* ]]
}

exige_palavra() {  # exige_palavra "RESTAURAR" "texto"
  ((SIM)) && return 0
  local r=""
  printf '\n%s %s\n    Para seguir, escreva %s e de enter: ' "$(cor '1;31' '!!!')" "$2" "$(cor '1;31' "$1")"
  read -r r </dev/tty || true
  [[ "$r" == "$1" ]]
}

na_saida() {
  local st=$?
  trap - EXIT INT TERM ERR
  # token de uso unico nao fica para tras nem se a execucao morrer no meio
  if ((TOKEN_FOI_CRIADO)); then apaga_token_api || true; fi
  [[ -n "$TEMP" && -d "$TEMP" ]] && rm -rf "$TEMP"
  exit "$st"
}

# ---------------------------------------------------------------------------
# Terreno
# ---------------------------------------------------------------------------
passo "Conferindo o terreno"
[[ $EUID -eq 0 ]] || morre "rode como root: sudo ./$NOME_SCRIPT ..."
for prog in tar gzip awk sed grep date sha256sum; do
  tem "$prog" || morre "falta o comando '$prog'"
done
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/restaurar-coolify-$CARIMBO.log"
: > "$LOG"
trap na_saida EXIT
trap 'morre "interrompido pelo operador"' INT TERM

FLAGS_EXTRACAO=(--numeric-owner -p)
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  # o teste e feito no modo de criacao porque ACL e xattr sao recurso de
  # compilacao do tar: se ele aceita na criacao, aceita na extracao. Testar com
  # "tar -tf /dev/null" nunca passa, porque /dev/null nao e um tar valido, e o
  # resultado seria restaurar sem ACL sem ninguem perceber.
  for f in --acls --xattrs --same-owner; do
    tar -cf /dev/null -T /dev/null "$f" >/dev/null 2>&1 && FLAGS_EXTRACAO+=("$f")
  done
  feito "GNU tar: extracao com ${FLAGS_EXTRACAO[*]}"
else
  aviso "o tar desta maquina nao e GNU: ACL e xattr nao serao devolvidos"
fi

# ---------------------------------------------------------------------------
# Abrir o pacote
# ---------------------------------------------------------------------------
passo "Abrindo o pacote"

# /var/tmp vem primeiro porque costuma ficar na particao maior e sobrevive a
# reinicio. Se nao existir ou nao couber, cai para /tmp e depois para a pasta
# onde o pacote esta.
escolhe_temp() {
  local precisa="${1:-0}" c melhor="" livre maior=-1
  for c in "$TEMP_PEDIDO" /var/tmp /tmp "$(dirname "${ARQUIVO:-$PASTA}")"; do
    [[ -n "$c" && -d "$c" && -w "$c" ]] || continue
    livre="$(df -P "$c" 2>/dev/null | awk 'NR==2{print ($4+0)*1024; exit}')" || livre=0
    [[ -n "$livre" ]] || livre=0
    if ((livre > maior)); then maior="$livre"; melhor="$c"; fi
  done
  [[ -n "$melhor" ]] || return 1
  if ((precisa > 0 && maior < precisa)); then
    aviso "a melhor pasta temporaria ($melhor) tem $(legivel "$maior") livre e a conta pede $(legivel "$precisa")"
  fi
  printf '%s\n' "$melhor"
}

TAM_PACOTE=0
[[ -n "$ARQUIVO" && -f "$ARQUIVO" ]] && TAM_PACOTE="$(stat -c%s "$ARQUIVO" 2>/dev/null || echo 0)"
BASE_TEMP="$(escolhe_temp $(( TAM_PACOTE * 12 / 10 )))" \
  || morre "nao achei pasta temporaria com permissao de escrita"
TEMP="$(mktemp -d "$BASE_TEMP/restaurar-coolify.XXXXXX")" \
  || morre "nao consegui criar pasta temporaria em $BASE_TEMP"
chmod 700 "$TEMP"
feito "area de trabalho: $TEMP"

if [[ -n "$PASTA" ]]; then
  [[ -d "$PASTA" ]] || morre "pasta nao encontrada: $PASTA"
  PACOTE="$(cd "$PASTA" && pwd -P)"
  feito "usando pacote ja aberto em $PACOTE"
else
  [[ -f "$ARQUIVO" ]] || morre "arquivo nao encontrado: $ARQUIVO"
  ARQUIVO="$(cd "$(dirname "$ARQUIVO")" && pwd -P)/$(basename "$ARQUIVO")"

  if [[ -f "$ARQUIVO.sha256" ]]; then
    diz "conferindo a soma do pacote"
    ( cd "$(dirname "$ARQUIVO")" && sha256sum -c "$(basename "$ARQUIVO").sha256" >/dev/null 2>&1 ) \
      && feito "SHA256 do pacote conferido" \
      || morre "a soma SHA256 do pacote nao bate: o arquivo veio corrompido na transferencia"
  else
    aviso "nao achei $ARQUIVO.sha256, seguindo sem conferir a soma do pacote"
  fi

  case "$ARQUIVO" in
    *.gpg)
      tem gpg || morre "o pacote esta cifrado com gpg e o gpg nao esta instalado"
      diz "decifrando"
      if [[ -n "$ARQUIVO_SENHA" ]]; then
        gpg --batch --yes --passphrase-file "$ARQUIVO_SENHA" -o "$TEMP/pacote.tar.gz" -d "$ARQUIVO" \
          || morre "nao consegui decifrar"
      else
        gpg -o "$TEMP/pacote.tar.gz" -d "$ARQUIVO" || morre "nao consegui decifrar"
      fi
      ARQUIVO="$TEMP/pacote.tar.gz"; feito "decifrado" ;;
    *.enc)
      tem openssl || morre "o pacote esta cifrado com openssl e o openssl nao esta instalado"
      diz "decifrando"
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$ARQUIVO" -out "$TEMP/pacote.tar.gz" \
        ${ARQUIVO_SENHA:+-pass "file:$ARQUIVO_SENHA"} || morre "nao consegui decifrar"
      ARQUIVO="$TEMP/pacote.tar.gz"; feito "decifrado" ;;
  esac

  diz "testando a integridade"
  gzip -t "$ARQUIVO" 2>>"$LOG" || morre "o pacote nao passou no gzip -t: arquivo corrompido"
  feito "gzip -t passou"

  diz "extraindo (pode demorar)"
  mkdir -p "$TEMP/aberto"
  tar -xzf "$ARQUIVO" -C "$TEMP/aberto" --numeric-owner 2>>"$LOG" \
    || morre "falhou ao extrair o pacote (veja $LOG)"
  PACOTE="$(find "$TEMP/aberto" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [[ -n "$PACOTE" && -d "$PACOTE" ]] || morre "o pacote nao tem a pasta esperada dentro"
  feito "aberto em $PACOTE"
fi

[[ -f "$PACOTE/00-meta/info.txt" ]] || morre "isto nao parece um pacote do backup-coolify.sh (falta 00-meta/info.txt)"

if [[ -f "$PACOTE/CHECKSUMS.sha256" ]]; then
  diz "conferindo as somas internas"
  if ( cd "$PACOTE" && sha256sum -c --quiet CHECKSUMS.sha256 2>>"$LOG" ); then
    feito "todos os arquivos internos conferem"
  else
    aviso "um ou mais arquivos internos nao conferem com o CHECKSUMS.sha256 (veja $LOG)"
  fi
fi

# ---------------------------------------------------------------------------
# Ler o manifesto
# ---------------------------------------------------------------------------
le_info() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$PACOTE/00-meta/info.txt" 2>/dev/null; }
ORIGEM="$(le_info maquina)"
VERSAO_ORIGEM="$(le_info versao_coolify)"
IMAGEM_ORIGEM="$(le_info imagem_coolify)"
ARQ_ORIGEM="$(le_info arquitetura)"
DATA_ORIGEM="$(le_info data)"
MODO_ORIGEM="$(le_info modo)"
TEM_IMAGENS="$(le_info imagens_incluidas)"
VERSAO_INSTALAR="${VERSAO_FORCADA:-$VERSAO_ORIGEM}"

QTD_VOL="$(conta "$PACOTE/03-volumes/_lista.tsv")"
QTD_BIND="$(conta "$PACOTE/04-binds/_mapa.tsv")"
QTD_BANCO="$(conta "$PACOTE/02-bancos/_bancos.tsv")"

# qual volume guarda o banco do painel. O nome vem do manifesto, porque depende
# de como o compose daquela versao do Coolify nomeia o volume.
VOL_PAINEL="$(le_info volume_banco_painel)"
[[ -n "$VOL_PAINEL" ]] || VOL_PAINEL="coolify-db"
if [[ -f "$PACOTE/03-volumes/_lista.tsv" ]] \
   && awk -F'\t' -v v="$VOL_PAINEL" '$1==v{achou=1} END{exit !achou}' "$PACOTE/03-volumes/_lista.tsv"; then
  TEM_VOLUME_COOLIFY_DB=1
fi
((VIA_DUMP)) && TEM_VOLUME_COOLIFY_DB=0


passo "O que tem neste pacote"
printf '  Origem ............. %s\n' "${ORIGEM:-?}"
printf '  Data do backup ..... %s\n' "${DATA_ORIGEM:-?}"
printf '  Modo do backup ..... %s\n' "${MODO_ORIGEM:-?}"
printf '  Coolify da origem .. %s\n' "${VERSAO_ORIGEM:-?}"
printf '  Arquitetura ........ %s (esta maquina: %s)\n' "${ARQ_ORIGEM:-?}" "$(uname -m)"
printf '  Volumes ............ %s\n' "$QTD_VOL"
printf '  Pastas de host ..... %s\n' "$QTD_BIND"
printf '  Bancos de dados .... %s\n' "$QTD_BANCO"
printf '  Imagens Docker ..... %s\n' "$( [[ "$TEM_IMAGENS" == 1 ]] && echo 'no pacote' || echo 'nao, serao baixadas' )"
printf '  Banco do painel .... %s\n' "$( ((TEM_VOLUME_COOLIFY_DB)) && echo 'volume do coolify-db (clone completo)' || echo 'dump logico (pg_restore)' )"

if [[ -n "$ARQ_ORIGEM" && "$ARQ_ORIGEM" != "$(uname -m)" ]]; then
  aviso "a origem era $ARQ_ORIGEM e esta maquina e $(uname -m). Imagem de arquitetura diferente nao roda: cada recurso vai precisar de deploy."
fi

if [[ -f "$PACOTE/02-bancos/_bancos.tsv" ]]; then
  printf '\n  Bancos guardados:\n'
  while IFS=$'\t' read -r nome eng metodo arq situacao; do
    [[ -n "$nome" ]] || continue
    printf '    %-40s %-11s %-22s %s\n' "$nome" "$eng" "$metodo" "$situacao"
  done < "$PACOTE/02-bancos/_bancos.tsv"
fi

if grep -q 'FALHAS ([1-9]' "$PACOTE/MANIFESTO.txt" 2>/dev/null; then
  aviso "o backup de origem registrou falhas. Leia o MANIFESTO.txt do pacote antes de seguir."
fi

if ((SO_CONFERIR)); then
  passo "Conferencia encerrada, nada foi alterado no servidor"
  printf '  Pacote aberto para leitura em: %s\n' "$PACOTE"
  printf '  Roteiro completo em: %s/RESTAURAR.md\n\n' "$PACOTE"
  TEMP=""   # deixa a pasta para o operador olhar
  exit 0
fi

# ---------------------------------------------------------------------------
# Docker e Coolify
# ---------------------------------------------------------------------------
passo "Preparando Docker e Coolify"

define_compose() {
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
  elif tem docker-compose; then COMPOSE="docker-compose"
  else COMPOSE=""; fi
}

instala_coolify() {
  local v="$1"
  tem curl || { aviso "curl nao esta instalado, nao consigo baixar o instalador"; return 1; }
  if ! curl -fsI --max-time 15 https://cdn.coollabs.io/coolify/install.sh >/dev/null 2>&1; then
    aviso "nao alcancei cdn.coollabs.io: sem internet para o instalador"
    return 1
  fi
  diz "instalando o Coolify ${v:-latest} (isso instala o Docker se faltar)"
  if [[ -n "$v" && "$v" != "desconhecida" && "$v" != "latest" ]]; then
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s "$v" >>"$LOG" 2>&1
  else
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash >>"$LOG" 2>&1
  fi
}

PRECISA_INSTALADOR=0
if ! tem docker || ! docker info >/dev/null 2>&1; then
  diz "o Docker nao esta pronto nesta maquina"
  PRECISA_INSTALADOR=1
elif [[ ! -d "$DIR_DADOS_COOLIFY/source" ]]; then
  diz "o Coolify ainda nao esta instalado aqui"
  PRECISA_INSTALADOR=1
else
  feito "Coolify ja presente: $(docker inspect --format '{{.Config.Image}}' coolify 2>/dev/null || echo 'containers parados')"
fi

if ((PRECISA_INSTALADOR)); then
  if ((SEM_INSTALAR)); then
    tem docker && docker info >/dev/null 2>&1 \
      || morre "--sem-instalar foi usado e o Docker nao esta funcionando. Instale o Docker e rode de novo."
    aviso "seguindo sem o instalador: vou subir a pilha do painel a partir do compose que veio no pacote"
  else
    if ! pergunta "Posso instalar o Coolify ${VERSAO_INSTALAR:-latest} nesta maquina agora?"; then
      morre "sem o Coolify instalado nao da para seguir. Use --sem-instalar se quiser subir so pelo compose do pacote."
    fi
    if instala_coolify "$VERSAO_INSTALAR"; then
      feito "Coolify instalado"
    else
      aviso "o instalador nao rodou. Vou tentar o caminho offline, usando o compose e as imagens do pacote."
      if [[ "$TEM_IMAGENS" != 1 ]]; then
        aviso "o pacote nao tem imagens: sem internet e sem imagem, a pilha nao sobe"
      fi
    fi
  fi
fi

tem docker && docker info >/dev/null 2>&1 || morre "o Docker nao responde. Resolva isso antes de restaurar."
define_compose
[[ -n "$COMPOSE" ]] || aviso "nao achei 'docker compose' nem 'docker-compose': vou subir a pilha com docker start"

# ---------------------------------------------------------------------------
# Guarda: nao atropelar um Coolify que ja tem dados
# ---------------------------------------------------------------------------
usuario_pg() { docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' coolify-db 2>/dev/null \
  | awk -F= '/^POSTGRES_USER=/{print $2; exit}'; }
banco_pg()   { docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' coolify-db 2>/dev/null \
  | awk -F= '/^POSTGRES_DB=/{print $2; exit}'; }

PG_USER="$(usuario_pg)"; [[ -n "$PG_USER" ]] || PG_USER=coolify
PG_DB="$(banco_pg)";     [[ -n "$PG_DB" ]]   || PG_DB=coolify

if docker ps -q -f 'name=^coolify-db$' | grep -q .; then
  QTD_APPS="$(docker exec coolify-db psql -U "$PG_USER" -d "$PG_DB" -At \
    -c "select count(*) from applications" 2>/dev/null || echo 0)"
  if [[ "${QTD_APPS:-0}" =~ ^[0-9]+$ ]] && ((QTD_APPS > 0)); then
    printf '\n%s\n' "$(cor '1;31' 'ATENCAO: ja existe um Coolify com dados nesta maquina.')"
    printf '  O painel atual tem %s aplicacao(oes) cadastrada(s).\n' "$QTD_APPS"
    printf '  Restaurar vai substituir o banco, os volumes e os arquivos por aqueles do pacote.\n'
    exige_palavra "RESTAURAR" "Isso sobrescreve os dados que estao aqui agora." \
      || morre "restauracao cancelada por voce"
  fi
fi

# quantos volumes desta maquina vao ser trocados pelo conteudo do pacote.
# A conta vem depois do instalador, porque ele mesmo cria os volumes do painel.
VOL_EM_USO=0
if [[ -f "$PACOTE/03-volumes/_lista.tsv" ]]; then
  while IFS=$'\t' read -r v _a; do
    [[ -n "$v" ]] || continue
    ponto="$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null || true)"
    if [[ -n "$ponto" && -d "$ponto" && -n "$(ls -A "$ponto" 2>/dev/null)" ]]; then
      VOL_EM_USO=$((VOL_EM_USO + 1))
    fi
  done < "$PACOTE/03-volumes/_lista.tsv"
fi

QTD_DE_PE="$(docker ps -q | awk 'END{print NR}')"
printf '\n%s\n' "$(cor '1' 'PLANO DE RESTAURACAO')"
PASSO_N=0
item() { PASSO_N=$((PASSO_N + 1)); printf '  %2d. %s\n' "$PASSO_N" "$1"; }

item "para os $QTD_DE_PE container(s) em execucao"
if ((TEM_VOLUME_COOLIFY_DB)); then
  item "devolve $DIR_DADOS_COOLIFY inteiro, com o .env e a APP_KEY da origem"
else
  item "devolve $DIR_DADOS_COOLIFY sem o .env do instalador, acertando so a APP_KEY"
fi
item "recria as redes Docker da origem"
if ((VOL_EM_USO > 0)); then
  if ((SOBRESCREVER)); then
    item "devolve $QTD_VOL volume(s), trocando $VOL_EM_USO que ja tem conteudo aqui"
  else
    item "devolve $QTD_VOL volume(s), preservando $VOL_EM_USO que ja tem conteudo aqui"
  fi
else
  item "devolve $QTD_VOL volume(s)"
fi
item "devolve $QTD_BIND pasta(s) de host"
[[ "$TEM_IMAGENS" == 1 ]] && item "carrega as imagens Docker do pacote"
((RESTAURA_SISTEMA)) && item "devolve daemon.json e crontab do sistema"
item "publica as chaves do Coolify no authorized_keys do root"
item "sobe a pilha do painel"
((TEM_VOLUME_COOLIFY_DB)) || item "restaura o banco do painel com pg_restore"
((DUMPS_BANCOS)) && item "reaplica os dumps logicos dos bancos de aplicacao"
((NAO_SUBIR)) || item "sobe os recursos que tem compose em disco"
if ((SEM_DEPLOY)); then
  item "nao dispara deploy nenhum (--sem-deploy)"
elif [[ -n "$API_TOKEN" ]]; then
  item "dispara deploy do que estava de pe na origem, com o token que voce passou"
else
  item "dispara deploy do que estava de pe na origem, com token de uso unico criado e apagado aqui"
fi

pergunta "Posso seguir com esse plano?" || morre "restauracao cancelada por voce"

# ---------------------------------------------------------------------------
# 1. Parar tudo
# ---------------------------------------------------------------------------
passo "Parando os containers"
mapfile -t DE_PE < <(docker ps -q 2>/dev/null || true)
if ((${#DE_PE[@]})); then
  docker stop "${DE_PE[@]}" >>"$LOG" 2>&1 || aviso "algum container resistiu ao stop"
  feito "${#DE_PE[@]} container(s) parado(s)"
else
  diz "nenhum container de pe"
fi

# ---------------------------------------------------------------------------
# 2. /data/coolify
# ---------------------------------------------------------------------------
passo "Devolvendo $DIR_DADOS_COOLIFY"
ARQ_DATA="$PACOTE/01-coolify/data-coolify.tar.gz"
if [[ -f "$ARQ_DATA" ]]; then
  mkdir -p "$DIR_DADOS_COOLIFY"
  if [[ -f "$DIR_DADOS_COOLIFY/source/.env" ]]; then
    cp -p "$DIR_DADOS_COOLIFY/source/.env" "$DIR_DADOS_COOLIFY/source/.env.antes-da-restauracao-$CARIMBO" 2>/dev/null || true
    feito "guardei o .env atual como .env.antes-da-restauracao-$CARIMBO"
  fi

  declare -a excecoes=()
  if ((TEM_VOLUME_COOLIFY_DB)); then
    diz "clone completo: o .env da origem volta junto, porque o volume do banco tambem volta"
  else
    excecoes+=(--exclude=./source/.env)
    diz "o .env do instalador fica, porque o banco vai ser restaurado por dump"
  fi

  if tar -xzf "$ARQ_DATA" -C "$DIR_DADOS_COOLIFY" "${FLAGS_EXTRACAO[@]}" \
       ${excecoes[@]+"${excecoes[@]}"} 2>>"$LOG"; then
    feito "$DIR_DADOS_COOLIFY devolvido"
  else
    falha "a extracao de $DIR_DADOS_COOLIFY terminou com erro (veja $LOG)"
  fi

  # permissao das chaves SSH: o Coolify nao usa chave com permissao aberta
  if [[ -d "$DIR_DADOS_COOLIFY/ssh/keys" ]]; then
    chmod 700 "$DIR_DADOS_COOLIFY/ssh" "$DIR_DADOS_COOLIFY/ssh/keys" 2>/dev/null || true
    find "$DIR_DADOS_COOLIFY/ssh/keys" -type f ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
    feito "permissao das chaves SSH ajustada"
  fi
else
  falha "o pacote nao tem 01-coolify/data-coolify.tar.gz"
fi

# APP_KEY, quando o caminho e por dump
if ((TEM_VOLUME_COOLIFY_DB == 0)); then
  passo "Acertando a APP_KEY no .env"
  CHAVE=""
  [[ -f "$PACOTE/01-coolify/APP_KEY.txt" ]] && \
    CHAVE="$(sed -n 's/^[[:space:]]*APP_KEY=//p' "$PACOTE/01-coolify/APP_KEY.txt" | head -1)"
  [[ -z "$CHAVE" && -f "$PACOTE/01-coolify/source.env" ]] && \
    CHAVE="$(sed -n 's/^[[:space:]]*APP_KEY=//p' "$PACOTE/01-coolify/source.env" | head -1)"
  ENV_VIVO="$DIR_DADOS_COOLIFY/source/.env"
  if [[ -n "$CHAVE" && -f "$ENV_VIVO" ]]; then
    if grep -q '^APP_KEY=' "$ENV_VIVO"; then
      sed -i "s|^APP_KEY=.*|APP_KEY=${CHAVE//|/\\|}|" "$ENV_VIVO"
    else
      printf 'APP_KEY=%s\n' "$CHAVE" >> "$ENV_VIVO"
    fi
    # carrega tambem outros valores que a origem definia e que nao quebram o
    # banco novo, para o painel nascer igual
    for k in APP_ID APP_URL AUTOUPDATE; do
      v="$(sed -n "s/^[[:space:]]*$k=//p" "$PACOTE/01-coolify/source.env" 2>/dev/null | head -1)"
      [[ -n "$v" ]] || continue
      if grep -q "^$k=" "$ENV_VIVO"; then sed -i "s|^$k=.*|$k=${v//|/\\|}|" "$ENV_VIVO"
      else printf '%s=%s\n' "$k" "$v" >> "$ENV_VIVO"; fi
    done
    feito "APP_KEY da origem gravada no .env (sem ela nenhum segredo seria lido)"
  else
    falha "nao achei a APP_KEY no pacote: o painel vai subir sem conseguir decifrar os segredos"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Redes
# ---------------------------------------------------------------------------
passo "Recriando as redes Docker"
criadas=0
if [[ -f "$PACOTE/00-meta/redes.tsv" ]]; then
  while IFS=$'\t' read -r nome driver subnet gateway attachable internal labels; do
    [[ -n "$nome" ]] || continue
    docker network inspect "$nome" >/dev/null 2>&1 && continue
    declare -a args=(--driver "${driver:-bridge}")
    [[ -n "$subnet" ]]  && args+=(--subnet "$subnet")
    [[ -n "$gateway" ]] && args+=(--gateway "$gateway")
    [[ "$attachable" == "true" ]] && args+=(--attachable)
    [[ "$internal" == "true" ]]   && args+=(--internal)
    if [[ -n "$labels" ]]; then
      IFS=',' read -r -a ls <<< "$labels"
      for l in ${ls[@]+"${ls[@]}"}; do [[ -n "$l" ]] && args+=(--label "$l"); done
    fi
    if docker network create "${args[@]}" "$nome" >>"$LOG" 2>&1; then
      criadas=$((criadas+1))
    else
      # sub-rede em conflito nesta maquina: cria sem fixar a faixa
      if docker network create --driver "${driver:-bridge}" "$nome" >>"$LOG" 2>&1; then
        criadas=$((criadas+1))
        aviso "rede $nome criada sem a sub-rede original (conflito de faixa nesta maquina)"
      else
        falha "nao consegui criar a rede $nome"
      fi
    fi
  done < "$PACOTE/00-meta/redes.tsv"
fi
feito "$criadas rede(s) criada(s), as que ja existiam ficaram como estao"

# ---------------------------------------------------------------------------
# 4. Volumes
# ---------------------------------------------------------------------------
passo "Devolvendo os volumes Docker"

meta_do_volume() {  # campo, nome -> valor
  [[ -f "$PACOTE/00-meta/volumes.tsv" ]] || return 0
  awk -F'\t' -v n="$2" -v c="$1" '$1==n{print $c; exit}' "$PACOTE/00-meta/volumes.tsv"
}

restaura_volume() {
  local vol="$1" arq="$PACOTE/03-volumes/$2"
  [[ -f "$arq" ]] || { falha "volume $vol: arquivo $2 nao esta no pacote"; return 1; }
  local driver labels ponto
  driver="$(meta_do_volume 2 "$vol")"; [[ -n "$driver" ]] || driver=local
  labels="$(meta_do_volume 3 "$vol")"

  if docker volume inspect "$vol" >/dev/null 2>&1; then
    ponto="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || echo '')"
    if [[ -n "$ponto" && -d "$ponto" && -n "$(ls -A "$ponto" 2>/dev/null)" ]]; then
      if ((SOBRESCREVER)); then
        find "$ponto" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG" || true
      else
        aviso "volume $vol ja existe com conteudo: pulei (use --sobrescrever para trocar)"
        return 0
      fi
    fi
  else
    declare -a args=(--driver "$driver")
    if [[ -n "$labels" ]]; then
      IFS=',' read -r -a ls <<< "$labels"
      for l in ${ls[@]+"${ls[@]}"}; do [[ -n "$l" ]] && args+=(--label "$l"); done
    fi
    docker volume create "${args[@]}" "$vol" >>"$LOG" 2>&1 \
      || { falha "nao consegui criar o volume $vol"; return 1; }
  fi

  ponto="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || echo '')"
  if [[ -n "$ponto" && -d "$ponto" ]]; then
    tar -xzf "$arq" -C "$ponto" "${FLAGS_EXTRACAO[@]}" 2>>"$LOG" \
      || { falha "volume $vol: a extracao falhou"; return 1; }
  else
    # driver fora do padrao: escreve por dentro de um container ajudante
    docker run --rm -i -v "$vol":/vol "$IMAGEM_AJUDANTE" \
      sh -c 'cd /vol && tar -xzf - --numeric-owner' < "$arq" >>"$LOG" 2>&1 \
      || { falha "volume $vol: a extracao pelo container ajudante falhou"; return 1; }
  fi
  return 0
}

vol_ok=0; vol_erro=0
if [[ -f "$PACOTE/03-volumes/_lista.tsv" ]]; then
  while IFS=$'\t' read -r vol arq; do
    [[ -n "$vol" && -n "$arq" ]] || continue
    if restaura_volume "$vol" "$arq"; then
      vol_ok=$((vol_ok+1)); printf '       %s\n' "$vol"
    else
      vol_erro=$((vol_erro+1))
    fi
  done < "$PACOTE/03-volumes/_lista.tsv"
fi
feito "$vol_ok volume(s) devolvido(s), $vol_erro com problema"

# ---------------------------------------------------------------------------
# 5. Pastas de host
# ---------------------------------------------------------------------------
passo "Devolvendo as pastas de host montadas em containers"
bind_ok=0
if [[ -f "$PACOTE/04-binds/_mapa.tsv" ]]; then
  while IFS=$'\t' read -r caminho arq tipo; do
    [[ -n "$caminho" && -n "$arq" ]] || continue
    [[ -f "$PACOTE/04-binds/$arq" ]] || { falha "bind $caminho: arquivo $arq nao esta no pacote"; continue; }
    if [[ "$tipo" == "arquivo" ]]; then
      mkdir -p "$(dirname "$caminho")"
      tar -xzf "$PACOTE/04-binds/$arq" -C "$(dirname "$caminho")" "${FLAGS_EXTRACAO[@]}" 2>>"$LOG" \
        && bind_ok=$((bind_ok+1)) || falha "bind $caminho: extracao falhou"
    else
      mkdir -p "$caminho"
      tar -xzf "$PACOTE/04-binds/$arq" -C "$caminho" "${FLAGS_EXTRACAO[@]}" 2>>"$LOG" \
        && bind_ok=$((bind_ok+1)) || falha "bind $caminho: extracao falhou"
    fi
    printf '       %s\n' "$caminho"
  done < "$PACOTE/04-binds/_mapa.tsv"
fi
feito "$bind_ok pasta(s) de host devolvida(s)"

# ---------------------------------------------------------------------------
# 6. Imagens
# ---------------------------------------------------------------------------
if [[ -f "$PACOTE/06-imagens/imagens.tar.gz" ]]; then
  passo "Carregando as imagens Docker do pacote"
  if gzip -dc "$PACOTE/06-imagens/imagens.tar.gz" | docker load >>"$LOG" 2>&1; then
    feito "imagens carregadas ($(conta "$PACOTE/06-imagens/_lista.txt") na lista)"
  else
    falha "docker load falhou (veja $LOG)"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Chaves SSH no authorized_keys
# ---------------------------------------------------------------------------
passo "Publicando as chaves do Coolify no authorized_keys do root"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
antes="$(conta /root/.ssh/authorized_keys)"

if [[ -s "$PACOTE/01-coolify/chaves-publicas.txt" ]]; then
  cat "$PACOTE/01-coolify/chaves-publicas.txt" >> /root/.ssh/authorized_keys
elif [[ -d "$DIR_DADOS_COOLIFY/ssh/keys" ]] && tem ssh-keygen; then
  for k in "$DIR_DADOS_COOLIFY"/ssh/keys/*; do
    [[ -f "$k" ]] || continue
    case "$k" in *.pub) continue ;; esac
    ssh-keygen -y -f "$k" 2>/dev/null >> /root/.ssh/authorized_keys || true
  done
fi
[[ -s "$PACOTE/05-sistema/root-authorized_keys" ]] && \
  cat "$PACOTE/05-sistema/root-authorized_keys" >> /root/.ssh/authorized_keys

awk 'NF && !vistas[$0]++' /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.novo \
  && mv /root/.ssh/authorized_keys.novo /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
depois="$(conta /root/.ssh/authorized_keys)"
feito "authorized_keys: $antes -> $depois chave(s). Sem isso o painel nao fala com o proprio servidor."

# ---------------------------------------------------------------------------
# Sistema (opcional)
# ---------------------------------------------------------------------------
if ((RESTAURA_SISTEMA)); then
  passo "Devolvendo configuracao de sistema"
  if [[ -f "$PACOTE/05-sistema/etc-docker-daemon.json" ]]; then
    if [[ -f /etc/docker/daemon.json ]]; then
      cp -p /etc/docker/daemon.json "/etc/docker/daemon.json.antes-$CARIMBO"
    fi
    install -D -m 644 "$PACOTE/05-sistema/etc-docker-daemon.json" /etc/docker/daemon.json
    aviso "daemon.json trocado. Para valer, o Docker precisa de 'systemctl restart docker' em uma janela sua."
  fi
  if [[ -f "$PACOTE/05-sistema/crontab-root.txt" ]] && tem crontab; then
    crontab -l > "/root/crontab.antes-$CARIMBO" 2>/dev/null || true
    crontab "$PACOTE/05-sistema/crontab-root.txt" && feito "crontab do root devolvido"
  fi
  # /etc/hosts, /etc/fstab e regra de firewall ficam de fora de proposito: em
  # maquina nova elas descrevem outro hardware e outra rede, e sobrescrever
  # pode cortar o acesso ao servidor. Ficam a mao para conferencia.
  for f in etc-hosts etc-fstab ufw.txt iptables.txt; do
    [[ -f "$PACOTE/05-sistema/$f" ]] || continue
    diz "para conferir a mao: $PACOTE/05-sistema/$f"
  done
fi

# ---------------------------------------------------------------------------
# 8. Subir a pilha do painel
# ---------------------------------------------------------------------------
passo "Subindo a pilha do painel"
FONTE="$DIR_DADOS_COOLIFY/source"
if [[ -n "$COMPOSE" && -f "$FONTE/docker-compose.yml" ]]; then
  declare -a arquivos=(-f docker-compose.yml)
  [[ -f "$FONTE/docker-compose.prod.yml" ]] && arquivos+=(-f docker-compose.prod.yml)
  if ( cd "$FONTE" && $COMPOSE --env-file .env "${arquivos[@]}" up -d --remove-orphans >>"$LOG" 2>&1 ); then
    feito "pilha do painel no ar pelo compose"
  else
    falha "o compose do painel falhou (veja $LOG). Tentando docker start."
    for c in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
      docker start "$c" >>"$LOG" 2>&1 || true
    done
  fi
else
  for c in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
    docker start "$c" >>"$LOG" 2>&1 && feito "$c de pe" || aviso "$c nao subiu"
  done
fi

espera_banco() {
  local n=0
  while ((n < 90)); do
    docker exec coolify-db pg_isready -U "$PG_USER" >/dev/null 2>&1 && return 0
    sleep 2; n=$((n+1))
  done
  return 1
}
# O .env restaurado pode definir usuario e banco diferentes dos que o
# instalador criou, por isso a leitura e refeita agora que a pilha ja subiu com
# o .env da origem.
atualiza_pg() {
  local u="" b=""
  u="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' coolify-db 2>/dev/null \
       | awk -F= '/^POSTGRES_USER=/{print $2; exit}')" || u=""
  b="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' coolify-db 2>/dev/null \
       | awk -F= '/^POSTGRES_DB=/{print $2; exit}')" || b=""
  if [[ -z "$u" && -f "$FONTE/.env" ]]; then
    u="$(sed -n 's/^[[:space:]]*DB_USERNAME=//p' "$FONTE/.env" | head -1)"
  fi
  if [[ -z "$b" && -f "$FONTE/.env" ]]; then
    b="$(sed -n 's/^[[:space:]]*DB_DATABASE=//p' "$FONTE/.env" | head -1)"
  fi
  [[ -n "$u" ]] && PG_USER="$u"
  [[ -n "$b" ]] && PG_DB="$b"
  return 0
}
atualiza_pg

# O proxy tem compose proprio, fora de /data/coolify/source, entao o compose do
# painel nao sobe ele. Sem proxy no ar, nenhum dominio responde.
passo "Subindo o proxy"
COMPOSE_PROXY=""
for c in "$DIR_DADOS_COOLIFY"/proxy/docker-compose.yml "$DIR_DADOS_COOLIFY"/proxy/docker-compose.yaml; do
  [[ -f "$c" ]] && { COMPOSE_PROXY="$c"; break; }
done
if [[ -n "$COMPOSE_PROXY" && -n "$COMPOSE" ]]; then
  if ( cd "$(dirname "$COMPOSE_PROXY")" && $COMPOSE -f "$(basename "$COMPOSE_PROXY")" up -d >>"$LOG" 2>&1 ); then
    feito "proxy no ar pelo compose dele"
  else
    docker start coolify-proxy >>"$LOG" 2>&1 \
      && feito "proxy no ar por docker start" \
      || falha "o proxy nao subiu. Em Servers > localhost > Proxy, clique em Start."
  fi
elif docker ps -aq -f 'name=^coolify-proxy$' | grep -q .; then
  docker start coolify-proxy >>"$LOG" 2>&1 \
    && feito "proxy no ar por docker start" \
    || falha "o proxy nao subiu. Em Servers > localhost > Proxy, clique em Start."
else
  aviso "nao achei o proxy nesta maquina. O painel cria ele em Servers > localhost > Proxy."
fi

diz "esperando o banco do painel responder (usuario $PG_USER)"
if espera_banco; then
  feito "coolify-db respondendo"
else
  falha "o coolify-db nao respondeu em 3 minutos"
  if ((TEM_VOLUME_COOLIFY_DB)); then
    aviso "causa mais provavel: a versao maior do Postgres desta instalacao nao abre o diretorio de dados da origem. Rode de novo com --via-dump, que restaura o painel pelo dump logico em vez do volume."
  fi
  diz "ultimas linhas do coolify-db:"
  docker logs --tail 20 coolify-db 2>&1 | sed 's/^/       /' || true
fi

# ---------------------------------------------------------------------------
# 9. Banco do painel por dump, quando o volume nao veio
# ---------------------------------------------------------------------------
if ((TEM_VOLUME_COOLIFY_DB == 0)); then
  passo "Restaurando o banco do painel pelo dump"
  DMP="$(find "$PACOTE/02-bancos" -name 'coolify.dmp' | head -1)"
  SQL="$(find "$PACOTE/02-bancos" -path '*coolify-db*' -name 'todos-os-bancos.sql.gz' | head -1)"
  docker stop coolify coolify-realtime coolify-redis >>"$LOG" 2>&1 || true

  if [[ -n "$DMP" && -f "$DMP" ]]; then
    diz "usando pg_restore em $(basename "$DMP")"
    if docker exec -i coolify-db pg_restore --clean --if-exists --no-owner --no-acl \
         --username "$PG_USER" --dbname "$PG_DB" < "$DMP" >>"$LOG" 2>&1; then
      feito "banco do painel restaurado"
    else
      aviso "o pg_restore reclamou de algo (comum com --clean em banco novo). Confira $LOG."
    fi
  elif [[ -n "$SQL" && -f "$SQL" ]]; then
    diz "usando o pg_dumpall em $(basename "$SQL")"
    if gzip -dc "$SQL" | docker exec -i coolify-db psql -U "$PG_USER" -d postgres >>"$LOG" 2>&1; then
      feito "banco do painel restaurado pelo pg_dumpall"
    else
      falha "a restauracao pelo pg_dumpall falhou (veja $LOG)"
    fi
  else
    falha "nao achei dump do banco do painel no pacote"
  fi

  diz "subindo o painel outra vez"
  if [[ -n "$COMPOSE" && -f "$FONTE/docker-compose.yml" ]]; then
    declare -a arquivos2=(-f docker-compose.yml)
    [[ -f "$FONTE/docker-compose.prod.yml" ]] && arquivos2+=(-f docker-compose.prod.yml)
    ( cd "$FONTE" && $COMPOSE --env-file .env "${arquivos2[@]}" up -d >>"$LOG" 2>&1 ) || true
  else
    for c in coolify-redis coolify-realtime coolify; do docker start "$c" >>"$LOG" 2>&1 || true; done
  fi
fi

# ---------------------------------------------------------------------------
# Dumps logicos dos bancos de aplicacao (opcional)
# ---------------------------------------------------------------------------
if ((DUMPS_BANCOS)); then
  passo "Reaplicando os dumps logicos dos bancos de aplicacao"
  aviso "os dados desses bancos ja voltaram pelos volumes. Reaplicar o dump por cima so faz sentido em troca de versao do motor."
  if [[ -f "$PACOTE/02-bancos/_bancos.tsv" ]]; then
    while IFS=$'\t' read -r nome eng metodo arq situacao; do
      [[ -n "$nome" && "$nome" != "coolify-db" ]] || continue
      [[ -n "$arq" && "$arq" != "-" ]] || continue
      [[ -f "$PACOTE/02-bancos/$arq" ]] || continue
      if ! docker ps -q -f "name=^${nome}$" | grep -q .; then
        aviso "$nome nao esta de pe nesta maquina ainda: reaplique o dump depois do deploy"
        continue
      fi
      case "$metodo" in
        pg_dumpall)
          gzip -dc "$PACOTE/02-bancos/$arq" | docker exec -i "$nome" psql -U postgres -d postgres >>"$LOG" 2>&1 \
            && feito "$nome: dump reaplicado" || falha "$nome: falha ao reaplicar" ;;
        mysqldump)
          gzip -dc "$PACOTE/02-bancos/$arq" | docker exec -i "$nome" sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD$MARIADB_ROOT_PASSWORD"' >>"$LOG" 2>&1 \
            && feito "$nome: dump reaplicado" || falha "$nome: falha ao reaplicar" ;;
        mongodump)
          docker exec -i "$nome" mongorestore --archive --gzip --drop < "$PACOTE/02-bancos/$arq" >>"$LOG" 2>&1 \
            && feito "$nome: dump reaplicado" || falha "$nome: falha ao reaplicar" ;;
        *) diz "$nome: metodo $metodo nao se reaplica por dump, o volume ja resolveu" ;;
      esac
    done < "$PACOTE/02-bancos/_bancos.tsv"
  fi
fi

# ---------------------------------------------------------------------------
# 10. Subir os recursos
# ---------------------------------------------------------------------------
if ((NAO_SUBIR == 0)); then
  passo "Subindo os recursos a partir dos compose em disco"
  if [[ -n "$COMPOSE" ]]; then
    while IFS= read -r arquivo; do
      [[ -n "$arquivo" ]] || continue
      pasta="$(dirname "$arquivo")"
      nome="$(basename "$pasta")"
      if ( cd "$pasta" && $COMPOSE -f "$(basename "$arquivo")" up -d --remove-orphans >>"$LOG" 2>&1 ); then
        SUBIRAM+=("$nome"); printf '       %s %s\n' "$(cor '0;32' 'subiu')" "$nome"
      else
        NAO_SUBIRAM+=("$nome"); printf '       %s %s\n' "$(cor '1;33' 'falhou')" "$nome"
      fi
    done < <(find "$DIR_DADOS_COOLIFY/applications" "$DIR_DADOS_COOLIFY/services" \
                -maxdepth 2 -name 'docker-compose.y*ml' 2>/dev/null | sort || true)
    feito "${#SUBIRAM[@]} recurso(s) de pe, ${#NAO_SUBIRAM[@]} sem subir por compose"
  else
    aviso "sem docker compose nesta maquina, nao consigo subir os recursos por aqui"
  fi
fi

# ---------------------------------------------------------------------------
# Lista de recursos no banco restaurado
# ---------------------------------------------------------------------------
psql_painel() {
  docker exec coolify-db psql -U "$PG_USER" -d "$PG_DB" -At -F'|' -c "$1" 2>/dev/null
}

passo "Lendo os recursos do painel restaurado"
declare -a RECURSOS=()
if docker ps -q -f 'name=^coolify-db$' | grep -q .; then
  TABELAS="applications services standalone_postgresqls standalone_mysqls standalone_mariadbs standalone_mongodbs standalone_redis standalone_keydbs standalone_dragonflies standalone_clickhouses"
  for t in $TABELAS; do
    [[ "$(psql_painel "select 1 from information_schema.tables where table_schema='public' and table_name='$t'")" == "1" ]] || continue
    while IFS='|' read -r nome uuid; do
      [[ -n "$nome" && -n "$uuid" ]] || continue
      RECURSOS+=("$t|$nome|$uuid")
    done < <(psql_painel "select name, uuid from $t" || true)
  done
fi
if ((${#RECURSOS[@]})); then
  feito "${#RECURSOS[@]} recurso(s) no painel"
else
  aviso "nao consegui ler os recursos do banco. Confira o painel direto."
fi

# ---------------------------------------------------------------------------
# Deploy automatico: traz de volta o que estava de pe na origem
#
# Container de aplicacao construida a partir de codigo nao existe na maquina
# nova, porque a imagem dela foi montada no servidor antigo. Quem recria isso e
# o deploy. Para nao exigir que voce crie um token na mao, o script cria um
# token de uso unico dentro do proprio painel, usa, e apaga no fim.
# ---------------------------------------------------------------------------
if [[ -z "$API_URL" ]]; then
  PORTA_API="$(sed -n 's/^[[:space:]]*APP_PORT=//p' "$FONTE/.env" 2>/dev/null | head -1)"
  [[ -n "$PORTA_API" ]] || PORTA_API=8000
  API_URL="http://localhost:$PORTA_API"
fi

espera_painel() {
  local n=0 codigo
  while ((n < 60)); do
    codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API_URL" 2>/dev/null || echo 000)"
    [[ "$codigo" != "000" ]] && return 0
    sleep 3; n=$((n + 1))
  done
  return 1
}

# Qualquer resposta autenticada serve de prova. Testa mais de um caminho porque
# a lista de rotas muda entre versoes do Coolify.
api_responde() {
  local rota
  for rota in /api/v1/version /api/v1/teams /api/v1/projects /api/v1/servers; do
    if curl -fsS --max-time 20 "$API_URL$rota" -H "Authorization: Bearer $1" >/dev/null 2>>"$LOG"; then
      return 0
    fi
  done
  return 1
}

# Usa o createToken do proprio Laravel, dentro do container do painel. Assim o
# formato e o hash do token saem certos sem SQL feito a mao.
cria_token_api() {
  local php saida id
  php="$(cat <<'PHP'
$u = App\Models\User::orderBy('id')->first();
if (! $u) { echo 'SEM_USUARIO'; return; }
echo $u->createToken('__NOME__', ['*'])->plainTextToken;
PHP
)"
  php="${php//__NOME__/$NOME_TOKEN}"
  saida="$(docker exec coolify php artisan tinker --execute "$php" 2>>"$LOG")" || return 1
  saida="$(printf '%s' "$saida" | tr -d '\r' | grep -oE '[0-9]+\|[A-Za-z0-9]{32,}' | head -1)"
  [[ -n "$saida" ]] || return 1
  id="${saida%%|*}"
  # algumas versoes guardam o time dentro do proprio token
  if [[ "$(psql_painel "select 1 from information_schema.columns where table_name='personal_access_tokens' and column_name='team_id'")" == "1" ]]; then
    psql_painel "update personal_access_tokens set team_id = coalesce(team_id, (select id from teams order by id limit 1)) where id = $id" >/dev/null
  fi
  printf '%s\n' "$saida"
}

apaga_token_api() {
  [[ -n "$NOME_TOKEN" ]] || return 0
  psql_painel "delete from personal_access_tokens where name = '$NOME_TOKEN'" >/dev/null 2>&1 || true
  TOKEN_FOI_CRIADO=0
  return 0
}

# So volta ao ar o que estava no ar na origem. Recurso que o dono tinha deixado
# parado continua parado, como estava.
estava_de_pe_na_origem() {
  [[ -f "$PACOTE/00-meta/containers.tsv" ]] || return 0
  awk -F'\t' -v u="$1" -v n="$2" '
    $3 == "running" {
      if (u != "" && index($1, u) > 0) ok = 1
      if (n != "" && $6 == n) ok = 1
    }
    END { exit !ok }' "$PACOTE/00-meta/containers.tsv"
}

ja_subiu_por_compose() {
  local x
  for x in ${SUBIRAM[@]+"${SUBIRAM[@]}"}; do [[ "$x" == "$1" ]] && return 0; done
  return 1
}

# Aplicacao e servico sobem por deploy. Banco gerenciado tem rota propria de
# start, com o deploy como reserva.
dispara_recurso() {
  local tabela="$1" uuid="$2"
  case "$tabela" in
    standalone_*)
      if curl -fsS --max-time 60 -X POST "$API_URL/api/v1/databases/$uuid/start" \
           -H "Authorization: Bearer $TOKEN_USO" >>"$LOG" 2>&1; then
        return 0
      fi ;;
  esac
  curl -fsS --max-time 60 "$API_URL/api/v1/deploy?uuid=$uuid&force=false" \
    -H "Authorization: Bearer $TOKEN_USO" >>"$LOG" 2>&1
}

declare -a DEPLOY_FEITO=() DEPLOY_RECUSADO=() DEPLOY_PULADO=()
TOKEN_USO=""

if ((SEM_DEPLOY)); then
  diz "deploy automatico desligado por --sem-deploy"
elif ((${#RECURSOS[@]} == 0)); then
  aviso "sem lista de recursos nao da para disparar deploy: use o painel"
else
  passo "Trazendo os recursos de volta ao ar"
  diz "painel em $API_URL"
  if ! espera_painel; then
    falha "o painel nao respondeu em 3 minutos, o deploy automatico nao rodou"
  else
    TOKEN_USO="$API_TOKEN"
    if [[ -n "$TOKEN_USO" ]]; then
      diz "usando o token que voce passou em --api-token"
    else
      diz "criando um token de uso unico no painel para disparar os deploys"
      TOKEN_USO="$(cria_token_api || true)"
      if [[ -n "$TOKEN_USO" ]]; then
        TOKEN_FOI_CRIADO=1
        feito "token temporario criado, sera apagado no fim"
      else
        aviso "nao consegui criar o token automatico nesta versao do Coolify"
      fi
    fi

    if [[ -z "$TOKEN_USO" ]] || ! api_responde "$TOKEN_USO"; then
      apaga_token_api
      falha "a API do painel nao aceitou o token, entao o deploy automatico nao rodou"
      aviso "de Deploy nos recursos pelo painel, ou crie um token em Keys & Tokens e rode: $NOME_SCRIPT --arquivo <pacote> --api-token SEU_TOKEN --nao-subir -s"
    else
      feito "API do painel autenticada"
      for r in "${RECURSOS[@]}"; do
        IFS='|' read -r tabela nome uuid <<< "$r"
        [[ -n "$uuid" ]] || continue
        if ja_subiu_por_compose "$uuid"; then
          DEPLOY_PULADO+=("$nome, ja subiu pelo compose")
          printf '       %s %s\n' "$(cor '0;90' 'pulado ')" "$nome"
          continue
        fi
        if ! estava_de_pe_na_origem "$uuid" "$nome"; then
          DEPLOY_PULADO+=("$nome, estava parado na origem")
          printf '       %s %s\n' "$(cor '0;90' 'pulado ')" "$nome"
          continue
        fi
        if dispara_recurso "$tabela" "$uuid"; then
          DEPLOY_FEITO+=("$nome")
          printf '       %s %s\n' "$(cor '0;32' 'na fila')" "$nome"
        else
          DEPLOY_RECUSADO+=("$nome")
          printf '       %s %s\n' "$(cor '1;33' 'recusado')" "$nome"
        fi
      done
      feito "${#DEPLOY_FEITO[@]} na fila, ${#DEPLOY_RECUSADO[@]} recusado(s), ${#DEPLOY_PULADO[@]} pulado(s)"
      ((${#DEPLOY_RECUSADO[@]})) && aviso "recurso recusado costuma ser o que o painel nao considera implantavel. Confira no painel."
      ((${#DEPLOY_FEITO[@]})) && diz "a fila do Coolify vai construir um por vez, acompanhe em Deployments no painel"
    fi
    apaga_token_api
  fi
fi
# ---------------------------------------------------------------------------
# Relatorio
# ---------------------------------------------------------------------------
DURACAO=$(( $(date +%s) - INICIO_EPOCH ))
ENDERECO="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || echo 'SEU_IP')"
PORTA_PAINEL="$(sed -n 's/^[[:space:]]*APP_PORT=//p' "$FONTE/.env" 2>/dev/null | head -1)"
[[ -n "$PORTA_PAINEL" ]] || PORTA_PAINEL=8000

printf '\n%s\n' "$(cor '1;32' '========================= RESTAURACAO CONCLUIDA =========================')"
printf '  Origem do pacote ... %s (%s)\n' "${ORIGEM:-?}" "${DATA_ORIGEM:-?}"
printf '  Duracao ............ %dm %ds\n' $((DURACAO/60)) $((DURACAO%60))
printf '  Volumes ............ %s devolvido(s), %s com problema\n' "$vol_ok" "$vol_erro"
printf '  Pastas de host ..... %s\n' "$bind_ok"
printf '  Banco do painel .... %s\n' "$( ((TEM_VOLUME_COOLIFY_DB)) && echo 'volume original (clone completo)' || echo 'restaurado por dump' )"
printf '  Recursos no painel . %s\n' "${#RECURSOS[@]}"
printf '  Subiram por compose  %s\n' "${#SUBIRAM[@]}"
printf '  Deploy na fila ..... %s\n' "${#DEPLOY_FEITO[@]}"
if ((${#DEPLOY_RECUSADO[@]})); then printf '  Deploy recusado .... %s\n' "${#DEPLOY_RECUSADO[@]}"; fi
if ((${#DEPLOY_PULADO[@]})); then printf '  Pulados ............ %s (parados na origem ou ja de pe)\n' "${#DEPLOY_PULADO[@]}"; fi
printf '  Avisos ............. %s\n' "${#AVISOS[@]}"
printf '  Falhas ............. %s\n' "${#ERROS[@]}"
printf '  Log .............. %s\n' "$LOG"

if ((${#ERROS[@]})); then
  printf '\n%s\n' "$(cor '1;31' 'FALHAS:')"
  for e in "${ERROS[@]}"; do printf '  - %s\n' "$e"; done
fi
if ((${#AVISOS[@]})); then
  printf '\n%s\n' "$(cor '1;33' 'AVISOS:')"
  for a in "${AVISOS[@]}"; do printf '  - %s\n' "$a"; done
fi

printf '\n%s\n' "$(cor '1' 'CONFIRA AGORA, NESTA ORDEM')"
printf '  1. Abra o painel em http://%s:%s e entre com a senha de antes.\n' "$ENDERECO" "$PORTA_PAINEL"
printf '     Se os projetos aparecem e nao ha erro de decifragem, a APP_KEY esta certa.\n'
printf '  2. Servers > localhost > Validate. Tem que passar.\n'
printf '  3. Cada banco de dados: de pe e aceitando conexao.\n'
printf '  4. Uma aplicacao abrindo no dominio, com os arquivos de usuario no lugar.\n'
if ((${#DEPLOY_FEITO[@]})); then
  printf '  5. Deployments no painel: %s recurso(s) entraram na fila e vao subir um\n' "${#DEPLOY_FEITO[@]}"
  printf '     por vez. Nada mais para fazer, so acompanhar.\n'
fi
if ((${#DEPLOY_RECUSADO[@]})); then
  printf '\n  %s\n' "$(cor '1;33' 'Recursos que a API recusou, de Deploy neles pelo painel:')"
  for d in "${DEPLOY_RECUSADO[@]}"; do printf '    - %s\n' "$d"; done
fi
if ((SEM_DEPLOY)); then
  printf '\n  O deploy ficou desligado por --sem-deploy. Para subir tudo que estava de pe\n'
  printf '  na origem, rode outra vez sem essa opcao:\n'
  printf '    sudo ./%s --arquivo <pacote> --nao-subir -s\n' "$NOME_SCRIPT"
fi
if [[ -n "$ARQ_ORIGEM" && "$ARQ_ORIGEM" != "$(uname -m)" ]]; then
  printf '\n  %s\n' "$(cor '1;33' "A origem era $ARQ_ORIGEM e esta maquina e $(uname -m): todo recurso precisa de deploy novo.")"
fi
printf '\n  %s\n\n' "$(cor '1;33' 'Se o servidor antigo continuar no ar com os mesmos recursos, desligue um dos dois: duas instancias gerenciando o mesmo dominio brigam entre si.')"

if ((${#ERROS[@]})); then exit 2; fi
exit 0
