#!/usr/bin/env bash
#
# backup-coolify.sh
# Backup total de um servidor Coolify em um unico arquivo .tar.gz.
#
# Guarda, em tres camadas que se cobrem:
#   1. dump logico de cada banco de dados, feito pela ferramenta do proprio banco
#   2. copia de todo volume Docker e de toda pasta de host montada em container
#   3. retrato do Docker (containers, volumes, redes, imagens, compose) e de
#      /data/coolify inteiro, incluindo a APP_KEY que decifra os segredos
#
# Uso:  sudo ./backup-coolify.sh
# Ajuda: ./backup-coolify.sh --ajuda
#
# Restauracao: use restaurar-coolify.sh com o arquivo gerado aqui.

set -Eeuo pipefail

VERSAO_SCRIPT="1.0.0"
NOME_SCRIPT="$(basename "$0")"

# ---------------------------------------------------------------------------
# Opcoes
# ---------------------------------------------------------------------------
DESTINO="/var/backups/coolify"
MODO="auto"                  # auto | quente | frio
INCLUIR_IMAGENS=0
INCLUIR_BACKUPS_COOLIFY=1
CIFRAR=0
ARQUIVO_SENHA=""
NIVEL_COMPRESSAO=6
IMAGEM_AJUDANTE="alpine:3.20"
SIMULAR=0
FORCAR=0
SIM=0
ENVIAR_DRIVE=0
DRIVE_SO_CONFIGURAR=0
DRIVE_RECONFIGURAR=0
DRIVE_REMOTE="coolify-drive"
DRIVE_PASTA=""
DRIVE_ESCOPO="total"
DRIVE_MANTER=0
DRIVE_CHAVE_PROPRIA=0
DRIVE_ENVIADO=""
SO_RELIGAR=0
DIR_DADOS_COOLIFY="/data/coolify"

# ---------------------------------------------------------------------------
# Estado interno
# ---------------------------------------------------------------------------
INICIO_EPOCH="$(date +%s)"
CARIMBO="$(date +%Y%m%d-%H%M%S)"
MAQUINA="$(hostname -s 2>/dev/null || echo servidor)"
NOME_PACOTE="coolify-backup-${MAQUINA}-${CARIMBO}"
TRABALHO=""                  # diretorio de montagem do pacote
LOG=""                       # arquivo de log (fora do diretorio de montagem)
ARQUIVO_FINAL=""
ARQUIVO_PARADOS=""           # lista persistida dos containers que paramos
declare -a CONTAINERS_PARADOS=()
declare -a AVISOS=()
declare -a ERROS=()
declare -a FLAGS_TAR=()
declare -a VOLUMES_PRONTOS=()
COMPRESSOR="gzip"
CORES=0

# ---------------------------------------------------------------------------
# Saida
# ---------------------------------------------------------------------------
cor() { if ((CORES)); then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
agora() { date '+%H:%M:%S'; }
diz()    { printf '%s %s\n' "$(cor '0;90' "[$(agora)]")" "$*"; }
passo()  { printf '\n%s %s\n' "$(cor '1;36' '==>')" "$(cor '1' "$*")"; }
feito()  { printf '%s %s\n' "$(cor '0;32' '  ok')" "$*"; }
aviso()  { AVISOS+=("$*"); printf '%s %s\n' "$(cor '1;33' '  !!')" "$*"; }
falha()  { ERROS+=("$*");  printf '%s %s\n' "$(cor '1;31' '  xx')" "$*"; }
morre()  { printf '\n%s %s\n' "$(cor '1;31' 'ERRO:')" "$*" >&2; exit 1; }

if [[ -t 1 ]]; then CORES=1; fi

ajuda() {
  cat <<AJUDA
$NOME_SCRIPT v$VERSAO_SCRIPT

Backup completo de um servidor Coolify em um unico arquivo .tar.gz, pronto para
restaurar em outra maquina com restaurar-coolify.sh.

USO
  sudo ./$NOME_SCRIPT [opcoes]

OPCOES
  -d, --destino DIR     Onde gravar o pacote. Padrao: $DESTINO
  -m, --modo MODO       auto | quente | frio. Padrao: auto
                          auto   nada para, exceto banco que nao aceita dump
                                 logico, que para pelo tempo da copia
                          quente nada para nunca (menor garantia em banco sem
                                 ferramenta de dump)
                          frio   dumps primeiro, depois para tudo, copia e
                                 religa o que estava de pe (garantia maxima)
      --imagens         Inclui as imagens Docker no pacote (docker save).
                        Fica muito maior. Serve para restaurar sem internet.
      --sem-backups     Nao inclui /data/coolify/backups (dumps antigos do
                        proprio Coolify). Reduz bastante o tamanho.
      --cifrar          Cifra o pacote com AES256. Gera .tar.gz.gpg
      --senha-arquivo F Le a senha da cifra do arquivo F em vez de perguntar
  -z, --compressao N    Nivel de compressao interno, 1 a 9. Padrao: $NIVEL_COMPRESSAO
      --simular         Mostra o que entraria e o tamanho estimado. Nao grava.
  -s, --sim             Responde sim as perguntas (uso no cron)

      --forcar          Ignora o aviso de espaco em disco insuficiente
      --religar         Nao faz backup. Religa containers que uma execucao
                        interrompida deixou parados.
  -h, --ajuda           Esta ajuda

GOOGLE DRIVE (envio opcional, pelo rclone)
      --google-drive    Depois de fechar o pacote, envia para o Google Drive.
                        Na primeira vez o script mostra um link: voce abre no
                        navegador, escolhe a conta Google, clica em Permitir,
                        copia a URL em que o navegador caiu e cola de volta
                        aqui. Acabou.
                        Nao precisa de projeto no Google Cloud, nem de chave,
                        nem de faturamento, e nao precisa instalar nada na sua
                        maquina: a autorizacao usa a chave que ja vem embutida
                        no rclone. Da segunda em diante vai sozinho.
      --drive-configurar  So faz a autorizacao e sai, sem backup. Use uma vez,
                        antes de agendar no cron.
      --drive-chave-propria  Em vez da chave do rclone, usa uma chave sua do
                        Google Cloud. Da cota maior, mas o Google passou a
                        exigir faturamento e verificacao. O script mostra as 5
                        telas, gera o link e voce cola a URL de volta.
      --drive-reconfigurar  Refaz a autorizacao mesmo se ja existir uma.
      --drive-pasta P   Pasta no Drive. Padrao: BackupCoolify/NOME_DA_MAQUINA
      --drive-remote N  Nome do remote no rclone. Padrao: coolify-drive
      --drive-escopo E  'total' (padrao) ou 'arquivos'. Com 'arquivos' o acesso
                        fica so no que o proprio script cria, mas aí ele nao
                        consegue enxergar pasta que voce criou a mao no Drive.
      --drive-manter N  Guarda os N pacotes mais novos na pasta do Drive e
                        remove os mais antigos. Padrao 0, que nao remove nada.

O QUE ENTRA NO PACOTE
  00-meta/      retrato do Docker: containers, volumes, redes, imagens, compose,
                versao do Coolify e do Docker
  01-coolify/   /data/coolify inteiro, mais a APP_KEY isolada
  02-bancos/    dump logico de cada banco (Postgres, MySQL, MariaDB, MongoDB,
                Redis e familia, ClickHouse)
  03-volumes/   um arquivo por volume Docker da maquina
  04-binds/     cada pasta de host montada dentro de algum container
  05-sistema/   daemon.json, crontab, authorized_keys, firewall, pacotes, rede
  06-imagens/   imagens Docker, somente com --imagens
  RESTAURAR.md  passo a passo gerado com os valores reais deste servidor
  CHECKSUMS.sha256, MANIFESTO.txt, backup.log

ATENCAO
  O pacote contem APP_KEY, senha de banco e chave SSH privada. Trate como
  segredo. Para guardar fora do servidor, use --cifrar.
AJUDA
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while (($#)); do
  case "$1" in
    -d|--destino)      DESTINO="${2:?caminho}"; shift 2 ;;
    -m|--modo)         MODO="${2:?modo}"; shift 2 ;;
    --imagens)         INCLUIR_IMAGENS=1; shift ;;
    --sem-backups)     INCLUIR_BACKUPS_COOLIFY=0; shift ;;
    --cifrar)          CIFRAR=1; shift ;;
    --senha-arquivo)   ARQUIVO_SENHA="${2:?arquivo}"; CIFRAR=1; shift 2 ;;
    -z|--compressao)   NIVEL_COMPRESSAO="${2:?nivel}"; shift 2 ;;
    --simular)         SIMULAR=1; shift ;;
    --forcar)          FORCAR=1; shift ;;
    -s|--sim)          SIM=1; shift ;;
    --google-drive)    ENVIAR_DRIVE=1; shift ;;
    --drive-configurar) DRIVE_SO_CONFIGURAR=1; shift ;;
    --drive-reconfigurar) DRIVE_RECONFIGURAR=1; DRIVE_SO_CONFIGURAR=1; shift ;;
    --drive-remote)    DRIVE_REMOTE="${2:?nome}"; shift 2 ;;
    --drive-pasta)     DRIVE_PASTA="${2:?pasta}"; shift 2 ;;
    --drive-escopo)    DRIVE_ESCOPO="${2:?escopo}"; shift 2 ;;
    --drive-manter)    DRIVE_MANTER="${2:?numero}"; shift 2 ;;
    --drive-chave-propria) DRIVE_CHAVE_PROPRIA=1; shift ;;
    --religar)         SO_RELIGAR=1; shift ;;
    -h|--ajuda|--help) ajuda; exit 0 ;;
    *) morre "opcao desconhecida: $1 (use --ajuda)" ;;
  esac
done

case "$MODO" in auto|quente|frio) ;; *) morre "modo invalido: $MODO" ;; esac
[[ "$NIVEL_COMPRESSAO" =~ ^[1-9]$ ]] || morre "compressao precisa ser de 1 a 9"
case "$DRIVE_ESCOPO" in total|arquivos) ;; *) morre "--drive-escopo aceita 'total' ou 'arquivos'" ;; esac
[[ "$DRIVE_MANTER" =~ ^[0-9]+$ ]] || morre "--drive-manter precisa ser um numero"

# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
tem() { command -v "$1" >/dev/null 2>&1; }

# Senha e nome de banco viajam em base64 para dentro do container. Base64 so
# tem letra, numero, mais, barra e igual, entao nunca precisa de escape e nao
# existe a classe de erro de aspas dentro de aspas. O valor nunca aparece na
# linha de comando do host.
b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }

conta() {  # linhas nao vazias de um arquivo, 0 se nao existir
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk 'NF{n++} END{print n+0}' "$1" 2>/dev/null || echo 0
}

legivel() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    s="B KB MB GB TB PB"; split(s,u," "); i=1;
    while (b>=1024 && i<6) { b/=1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

tamanho_de() {
  local alvo="$1" v=""
  [[ -e "$alvo" ]] || { echo 0; return 0; }
  # du pode terminar com erro por uma subpasta sem permissao e ainda assim
  # imprimir o total certo, por isso o status dele nao decide nada aqui
  v="$(du -sx --block-size=1 "$alvo" 2>/dev/null | awk 'NR==1{print $1+0; exit}')" || v=""
  if [[ -z "$v" || "$v" == 0 ]]; then
    v="$(du -sxk "$alvo" 2>/dev/null | awk 'NR==1{print ($1+0)*1024; exit}')" || v=""
  fi
  [[ -n "$v" ]] || v=0
  printf '%s\n' "$v"
}

espaco_livre() {
  local v=""
  v="$(df -P "$1" 2>/dev/null | awk 'NR==2{print ($4+0)*1024; exit}')" || v=""
  [[ -n "$v" ]] || v=0
  printf '%s\n' "$v"
}

slug() {
  printf '%s' "$1" | sed 's#^/##; s#/#_#g; s#[^A-Za-z0-9._-]#-#g' | cut -c1-180
}

# roda um script sh (vindo pelo stdin) dentro de um container, sem expor
# segredo no ps do host. A saida do script vai para o stdout desta funcao.
roda_no_container() {
  local id="$1"
  local alvo="/tmp/.bkp-coolify-$$.sh"
  if ! docker exec -i "$id" sh -c "umask 077; cat > $alvo" 2>/dev/null; then
    return 127
  fi
  local st=0
  docker exec "$id" sh "$alvo" || st=$?
  docker exec "$id" rm -f "$alvo" >/dev/null 2>&1 || true
  return "$st"
}

env_do_container() {
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | awk -v k="$2=" 'index($0,k)==1 { print substr($0, length(k)+1); exit }'
}

nome_do_container() {
  docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's#^/##'
}

# tar com as melhores flags disponiveis, tolerando arquivo que muda durante a
# leitura (exit 1 do GNU tar e aviso, nao falha)
tar_para_arquivo() {
  local origem="$1" saida="$2"; shift 2
  local st=0
  set +e
  tar "${FLAGS_TAR[@]}" "$@" -cf - -C "$origem" . 2>>"$LOG" | $COMPRESSOR > "$saida"
  local estados=("${PIPESTATUS[@]}")
  set -e
  st="${estados[0]}"
  if ((st == 1)); then
    aviso "arquivos mudaram durante a leitura de $origem (normal em servidor no ar)"
    st=0
  fi
  [[ "${estados[1]:-0}" == 0 ]] || st=1
  return "$st"
}

# ---------------------------------------------------------------------------
# Limpeza e religamento
# ---------------------------------------------------------------------------
religa_containers() {
  ((${#CONTAINERS_PARADOS[@]})) || return 0
  diz "religando ${#CONTAINERS_PARADOS[@]} container(s)"
  local c
  # ordem: a pilha do Coolify primeiro, depois o resto
  for c in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
    local i
    for i in "${!CONTAINERS_PARADOS[@]}"; do
      if [[ "${CONTAINERS_PARADOS[$i]}" == "$c" ]]; then
        docker start "$c" >/dev/null 2>&1 || aviso "nao consegui religar $c"
        unset 'CONTAINERS_PARADOS[i]'
      fi
    done
  done
  for c in ${CONTAINERS_PARADOS[@]+"${CONTAINERS_PARADOS[@]}"}; do
    docker start "$c" >/dev/null 2>&1 || aviso "nao consegui religar $c"
  done
  CONTAINERS_PARADOS=()
  [[ -n "$ARQUIVO_PARADOS" && -f "$ARQUIVO_PARADOS" ]] && rm -f "$ARQUIVO_PARADOS"
  return 0
}

na_saida() {
  local st=$?
  trap - EXIT INT TERM ERR
  religa_containers || true
  if [[ -n "$TRABALHO" && -d "$TRABALHO" && $st -ne 0 ]]; then
    diz "mantendo $TRABALHO para conferencia (a execucao nao terminou bem)"
  elif [[ -n "$TRABALHO" && -d "$TRABALHO" ]]; then
    rm -rf "$TRABALHO"
  fi
  exit "$st"
}

# ---------------------------------------------------------------------------
# Modo --religar
# ---------------------------------------------------------------------------
if ((SO_RELIGAR)); then
  [[ $EUID -eq 0 ]] || morre "rode como root"
  encontrou=0
  for f in "$DESTINO"/.containers-parados-*.txt; do
    [[ -f "$f" ]] || continue
    encontrou=1
    diz "lendo $f"
    while read -r c; do
      [[ -n "$c" ]] || continue
      if docker start "$c" >/dev/null 2>&1; then feito "religado: $c"
      else aviso "nao consegui religar: $c"; fi
    done < "$f"
    rm -f "$f"
  done
  ((encontrou)) || diz "nada pendente para religar"
  exit 0
fi

# ---------------------------------------------------------------------------
# Verificacoes antes de comecar
# ---------------------------------------------------------------------------
passo "Conferindo o terreno"

[[ $EUID -eq 0 ]] || morre "rode como root: sudo ./$NOME_SCRIPT"

for prog in docker tar gzip awk sed date hostname du df sha256sum; do
  tem "$prog" || morre "falta o comando '$prog' nesta maquina"
done

docker info >/dev/null 2>&1 || morre "o Docker nao responde (servico parado ou sem permissao)"
feito "Docker respondendo: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

# GNU tar guarda dono numerico, ACL e xattr. BusyBox tar nao.
FLAGS_TAR=(--numeric-owner)
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  for f in --acls --xattrs --ignore-failed-read --warning=no-file-changed --warning=no-file-removed; do
    if tar -cf /dev/null -T /dev/null "$f" >/dev/null 2>&1; then FLAGS_TAR+=("$f"); fi
  done
  feito "GNU tar com ${#FLAGS_TAR[@]} opcoes de preservacao"
else
  aviso "o tar desta maquina nao e GNU: ACL e xattr nao serao guardados"
fi

if tem pigz; then
  COMPRESSOR="pigz -${NIVEL_COMPRESSAO}"
  feito "pigz presente, compressao em paralelo"
else
  COMPRESSOR="gzip -${NIVEL_COMPRESSAO}"
fi

if [[ ! -d "$DIR_DADOS_COOLIFY" ]]; then
  aviso "$DIR_DADOS_COOLIFY nao existe: este servidor tem Coolify instalado?"
fi

# o destino nao pode morar dentro do que vamos copiar
mkdir -p "$DESTINO" || morre "nao consegui criar $DESTINO"
DESTINO="$(cd "$DESTINO" && pwd -P)"
case "$DESTINO" in
  "$DIR_DADOS_COOLIFY"|"$DIR_DADOS_COOLIFY"/*)
    morre "o destino nao pode ficar dentro de $DIR_DADOS_COOLIFY (o backup copiaria a si mesmo)" ;;
  /var/lib/docker|/var/lib/docker/*)
    morre "o destino nao pode ficar dentro de /var/lib/docker" ;;
esac
feito "destino: $DESTINO"

if [[ -n "$ARQUIVO_SENHA" && ! -r "$ARQUIVO_SENHA" ]]; then
  morre "nao consigo ler o arquivo de senha: $ARQUIVO_SENHA"
fi
if ((CIFRAR)) && ! tem gpg && ! tem openssl; then
  morre "--cifrar precisa de gpg ou openssl instalado"
fi

# trava para nao rodar duas vezes ao mesmo tempo
TRAVA="$DESTINO/.backup.lock"
if tem flock; then
  exec 9>"$TRAVA"
  flock -n 9 || morre "ja existe um backup em andamento (trava: $TRAVA)"
fi

LOG="$DESTINO/.${NOME_PACOTE}.log"
: > "$LOG"
ARQUIVO_PARADOS="$DESTINO/.containers-parados-${CARIMBO}.txt"

trap na_saida EXIT
trap 'morre "interrompido pelo operador"' INT TERM

# ---------------------------------------------------------------------------
# Google Drive
#
# O transporte e o rclone, igual ao DevBackup. A diferenca e a autorizacao:
# servidor nao tem navegador, entao em vez de o rclone abrir o navegador, o
# script monta o link, voce abre no seu computador, autoriza, e cola de volta a
# URL em que o Google caiu. Dessa URL sai o codigo, que vira token.
#
# O token fica em rclone.conf com permissao 600. O rclone renova o acesso
# sozinho depois, sem pedir nada de novo.
# ---------------------------------------------------------------------------
# Este e exatamente o redirecionamento que o rclone registra no Google. Usar o
# mesmo tira qualquer duvida de correspondencia: o Google exige que o valor
# mandado aqui bata com o que esta registrado na chave.
REDIRECIONAMENTO="http://127.0.0.1:53682/"
REDIRECIONAMENTO_CODIFICADO="http%3A%2F%2F127.0.0.1%3A53682%2F"

escopo_oauth() {
  case "$DRIVE_ESCOPO" in
    arquivos) printf 'https://www.googleapis.com/auth/drive.file' ;;
    *)        printf 'https://www.googleapis.com/auth/drive' ;;
  esac
}
escopo_codificado() {
  case "$DRIVE_ESCOPO" in
    arquivos) printf 'https%%3A%%2F%%2Fwww.googleapis.com%%2Fauth%%2Fdrive.file' ;;
    *)        printf 'https%%3A%%2F%%2Fwww.googleapis.com%%2Fauth%%2Fdrive' ;;
  esac
}

# -r /dev/tty so diz se o no tem permissao de leitura, e responde que sim mesmo
# quando o processo nao tem terminal de controle, como no cron. O jeito honesto
# e tentar abrir o dispositivo.
tem_terminal() { ( exec 3<>/dev/tty ) 2>/dev/null; }

pergunta_sim() {
  local r=""
  ((SIM)) && return 0
  tem_terminal || return 1
  printf '  %s [s/N] ' "$1" > /dev/tty
  read -r r < /dev/tty || true
  [[ "$r" == [sS]* ]]
}

le_do_tty() {  # le_do_tty "rotulo" [oculto]
  local r=""
  tem_terminal || return 1
  printf '  %s: ' "$1" > /dev/tty
  if [[ "${2:-}" == "oculto" ]]; then
    read -r -s r < /dev/tty || true
    printf '\n' > /dev/tty
  else
    read -r r < /dev/tty || true
  fi
  printf '%s' "$r"
}

# pega o valor de uma chave de texto no JSON, sem depender de jq
valor_json() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
numero_json() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p" | head -1
}

instala_rclone() {
  tem rclone && return 0
  passo "Instalando o rclone (transporte para o Google Drive)"
  # pacote da distribuicao primeiro, porque vem assinado pelo repositorio
  if tem apt-get; then
    diz "tentando pelo apt"
    DEBIAN_FRONTEND=noninteractive apt-get install -y rclone >>"$LOG" 2>&1 && tem rclone && {
      feito "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}') instalado pelo apt"; return 0; }
  elif tem dnf; then
    dnf install -y rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo dnf"; return 0; }
  elif tem yum; then
    yum install -y rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo yum"; return 0; }
  elif tem apk; then
    apk add --no-cache rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo apk"; return 0; }
  elif tem pacman; then
    pacman -Sy --noconfirm rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo pacman"; return 0; }
  fi
  aviso "o gerenciador de pacotes nao tinha o rclone"
  printf '\n  O jeito oficial de instalar e baixar e rodar o script do site do rclone:\n'
  printf '    curl https://rclone.org/install.sh | sudo bash\n\n'
  printf '  Isso baixa e executa um script de rclone.org nesta maquina.\n'
  if pergunta_sim "Autoriza esse download e execucao?"; then
    tem curl || { falha "preciso do curl para baixar o instalador"; return 1; }
    if curl -fsSL https://rclone.org/install.sh 2>>"$LOG" | bash >>"$LOG" 2>&1 && tem rclone; then
      feito "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}') instalado"
      return 0
    fi
    falha "a instalacao do rclone nao terminou (veja $LOG)"
    return 1
  fi
  falha "sem rclone nao da para enviar ao Drive. Instale a mao e rode de novo."
  return 1
}

arquivo_conf_rclone() {
  local c=""
  c="$(rclone config file 2>/dev/null | tail -1 | tr -d '\r')" || c=""
  [[ -n "$c" ]] || c="/root/.config/rclone/rclone.conf"
  printf '%s' "$c"
}

remote_ja_existe() {
  rclone listremotes 2>/dev/null | grep -qx "${DRIVE_REMOTE}:"
}

testa_remote() {
  rclone lsd "${DRIVE_REMOTE}:" >/dev/null 2>>"$LOG"
}

# Escreve a secao do remote no rclone.conf sem apagar o que ja esta la.
escreve_remote_rclone() {
  local id="$1" secret="$2" token="$3" escopo="${4:-}"
  local conf; conf="$(arquivo_conf_rclone)"
  mkdir -p "$(dirname "$conf")" && chmod 700 "$(dirname "$conf")" 2>/dev/null || true
  if [[ -f "$conf" ]]; then
    cp -p "$conf" "$conf.antes-$CARIMBO" 2>/dev/null || true
    # remove uma secao com o mesmo nome, se houver, preservando as outras
    awk -v alvo="[$DRIVE_REMOTE]" '
      /^\[/ { dentro = ($0 == alvo) }
      !dentro { print }
    ' "$conf" > "$conf.novo" && mv "$conf.novo" "$conf"
  fi
  umask 077
  # separa da secao anterior quando o arquivo nao termina em linha em branco
  if [[ -s "$conf" ]] && [[ -n "$(tail -c 2 "$conf" | tr -d '\n')" ]]; then
    printf '\n' >> "$conf"
  fi
  {
    printf '[%s]\n' "$DRIVE_REMOTE"
    printf 'type = drive\n'
    # Sem chave propria as duas linhas ficam de fora de proposito: assim o
    # rclone usa a chave que vem embutida nele, inclusive para renovar o
    # acesso. Gravar client_id vazio faria a renovacao falhar.
    [[ -n "$id" ]]     && printf 'client_id = %s\n' "$id"
    [[ -n "$secret" ]] && printf 'client_secret = %s\n' "$secret"
    [[ -n "$escopo" ]] && printf 'scope = %s\n' "$escopo"
    printf 'token = %s\n' "$token"
    printf '\n'
  } >> "$conf"
  chmod 600 "$conf"
  feito "remote '$DRIVE_REMOTE' gravado em $conf"
}

# ---------------------------------------------------------------------------
# Autorizacao: um link, e a URL de volta. So isso.
#
# O script monta o link, voce abre no navegador do seu computador, escolhe a
# conta Google e clica em Permitir. O Google devolve o navegador para
# 127.0.0.1:53682, que nao tem ninguem escutando, entao a pagina da erro. Isso e
# o esperado: o que importa esta na barra de endereco. Voce copia a URL inteira,
# cola aqui, e o script troca o codigo dela por um token.
#
# No caminho padrao a chave usada e a que ja vem embutida no proprio rclone,
# publicada no codigo dele. Credencial de aplicativo instalado nao e
# confidencial por desenho, e e por usar essa que nao existe projeto no Google
# Cloud para criar, nem faturamento, nem tela de verificacao. O token gravado
# sai sem client_id e sem client_secret, para o rclone renovar o acesso com a
# chave dele mesmo.
#
# Quem quiser cota maior usa --drive-chave-propria, que percorre as cinco telas
# do Google Cloud e cai na MESMA funcao daqui, so que com a chave dele.
# ---------------------------------------------------------------------------
CLIENTE_RCLONE="202264815644.apps.googleusercontent.com"
SEGREDO_RCLONE="X4Z3ca8xfWDb1Voo-F9a7ZxJ"

# autoriza_por_link <client_id> <client_secret> <grava_a_chave_no_conf>
autoriza_por_link() {
  local id="$1" segredo="$2" grava="${3:-0}"

  # PKCE, quando houver openssl. Protege a troca do codigo pelo token.
  local verificador="" desafio="" parte_pkce=""
  if tem openssl; then
    verificador="$(openssl rand -base64 48 2>/dev/null | tr -d '\n\r=' | tr '+/' '-_')"
    desafio="$(printf '%s' "$verificador" | openssl dgst -binary -sha256 2>/dev/null \
               | openssl base64 2>/dev/null | tr -d '\n\r=' | tr '+/' '-_')"
    if [[ -n "$verificador" && -n "$desafio" ]]; then
      parte_pkce="&code_challenge=$desafio&code_challenge_method=S256"
    else
      verificador=""
    fi
  fi

  local url
  url="https://accounts.google.com/o/oauth2/v2/auth?client_id=${id}"
  url="${url}&redirect_uri=${REDIRECIONAMENTO_CODIFICADO}&response_type=code"
  url="${url}&scope=$(escopo_codificado)&access_type=offline&prompt=consent${parte_pkce}"

  {
    printf '\n'
    printf '  ABRA ESTE LINK NO NAVEGADOR DO SEU COMPUTADOR:\n\n'
    printf '%s\n\n' "$url"
    printf '  1. escolha a conta Google onde o backup vai ficar;\n'
    printf '  2. se aparecer aviso de aplicativo nao verificado, clique em\n'
    printf '     Avancado e depois em Acessar;\n'
    printf '  3. clique em Permitir;\n'
    printf '  4. a pagina seguinte vai dizer que nao conseguiu acessar\n'
    printf '     127.0.0.1. E isso mesmo, nao deu errado: o endereco dela E a\n'
    printf '     sua resposta. Copie a barra de endereco INTEIRA e cole aqui.\n\n'
    printf '  A URL comeca com %s e tem code= no meio.\n\n' "$REDIRECIONAMENTO"
  } > /dev/tty

  local colado codigo
  colado="$(le_do_tty 'Cole a URL completa')"
  codigo="$(printf '%s' "$colado" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' | head -1)"
  [[ -n "$codigo" ]] || codigo="$(printf '%s' "$colado" | tr -d '[:space:]')"
  if [[ -z "$codigo" ]]; then
    falha "nao achei o code= no que voce colou"
    aviso "cole a URL inteira da barra de endereco, a que comeca com $REDIRECIONAMENTO"
    return 1
  fi
  case "$colado" in
    *error=access_denied*) falha "a autorizacao foi recusada na tela do Google"; return 1 ;;
    *error=*)              falha "o Google devolveu um erro na URL: ${colado#*error=}"; return 1 ;;
  esac
  codigo="$(printf '%s' "$codigo" | sed 's/%2F/\//g; s/%2f/\//g')"

  # troca o codigo pelo token. Tudo por arquivo, para o segredo e o token nao
  # aparecerem na linha de comando do servidor.
  diz "trocando o codigo por um token"
  local d resposta acesso atualizacao segundos expiracao erro
  d="$(mktemp -d)"; chmod 700 "$d"
  umask 077
  printf '%s' "$codigo"           > "$d/code"
  printf '%s' "$id"               > "$d/id"
  printf '%s' "$segredo"          > "$d/secret"
  printf '%s' "$REDIRECIONAMENTO" > "$d/redirect"
  [[ -n "$verificador" ]] && printf '%s' "$verificador" > "$d/verifier"

  declare -a extra=()
  [[ -n "$verificador" ]] && extra=(--data-urlencode "code_verifier@$d/verifier")

  resposta="$(curl -fsS --max-time 60 https://oauth2.googleapis.com/token \
    --data-urlencode "code@$d/code" \
    --data-urlencode "client_id@$d/id" \
    --data-urlencode "client_secret@$d/secret" \
    --data-urlencode "redirect_uri@$d/redirect" \
    ${extra[@]+"${extra[@]}"} \
    -d grant_type=authorization_code 2>>"$LOG")" || resposta=""
  rm -rf "$d"

  if [[ -z "$resposta" ]]; then
    falha "o Google nao aceitou a troca do codigo pelo token"
    aviso "o codigo vale poucos minutos. Rode --drive-configurar de novo e cole a URL logo depois de autorizar."
    return 1
  fi

  erro="$(valor_json "$resposta" error)"
  if [[ -n "$erro" ]]; then
    falha "o Google recusou: $erro"
    [[ "$erro" == "invalid_grant" ]] && aviso "o codigo ja foi usado ou venceu. Autorize de novo e cole a URL na hora."
    return 1
  fi

  acesso="$(valor_json "$resposta" access_token)"
  atualizacao="$(valor_json "$resposta" refresh_token)"
  segundos="$(numero_json "$resposta" expires_in)"
  [[ -n "$segundos" ]] || segundos=3600

  if [[ -z "$acesso" ]]; then
    falha "a resposta do Google nao trouxe access_token"
    return 1
  fi
  if [[ -z "$atualizacao" ]]; then
    falha "a resposta do Google nao trouxe refresh_token, entao o envio pararia de funcionar em uma hora"
    aviso "isso acontece quando esta conta ja autorizou antes. Remova o acesso em myaccount.google.com/permissions e autorize de novo."
    return 1
  fi

  expiracao="$(date -u -d "+${segundos} seconds" '+%Y-%m-%dT%H:%M:%S.000000000Z' 2>/dev/null)" \
    || expiracao="$(date -u '+%Y-%m-%dT%H:%M:%S.000000000Z')"

  local token="{\"access_token\":\"$acesso\",\"token_type\":\"Bearer\",\"refresh_token\":\"$atualizacao\",\"expiry\":\"$expiracao\"}"
  if ((grava)); then
    # chave propria: o rclone precisa dela gravada para renovar o acesso
    escreve_remote_rclone "$id" "$segredo" "$token" "$(escopo_oauth)"
  else
    # chave do rclone: as duas linhas ficam de fora de proposito, para ele usar
    # a chave embutida tambem na renovacao
    escreve_remote_rclone "" "" "$token" "$(escopo_conf_curto)"
  fi
  return 0
}

escopo_conf_curto() {
  case "$DRIVE_ESCOPO" in
    arquivos) printf 'drive.file' ;;
    *)        printf 'drive' ;;
  esac
}

# ---------------------------------------------------------------------------
# Caminho alternativo: chave propria no Google Cloud
#
# Serve para quem quer a cota maior. O Google passou a exigir faturamento e
# verificacao em muitos casos, entao isso nao e o caminho padrao daqui.
# ---------------------------------------------------------------------------
mostra_passos_da_chave() {
  cat <<'PASSOS'

  Voce escolheu criar a sua propria chave de acesso ao Google. Abra estas 5
  paginas no SEU computador, na ordem:

  PASSO 1, criar um projeto
    https://console.cloud.google.com/projectcreate
    Nome do projeto: Backup Coolify. Clique em Criar e espere.

  PASSO 2, ligar a API do Google Drive
    https://console.cloud.google.com/apis/library/drive.googleapis.com
    Confira no topo se o projeto selecionado e o Backup Coolify.
    Clique no botao azul Ativar.

  PASSO 3, identificar o aplicativo
    https://console.cloud.google.com/auth/branding
    Nome do app: Backup Coolify
    E-mail de suporte: o seu
    Publico: Externo
    Informacoes de contato: o seu e-mail. Aceite o termo e clique em Criar.

  PASSO 4, liberar o seu proprio e-mail
    https://console.cloud.google.com/auth/audience
    Na secao Usuarios de teste, clique em Adicionar usuarios, coloque o seu
    e-mail do Google e salve. Sem isso o Google recusa a autorizacao.

  PASSO 5, criar a chave
    https://console.cloud.google.com/auth/clients/create
    Tipo de aplicativo: App para computador
    Clique em Criar. Vai aparecer uma janela com dois codigos.
    Deixe ela aberta, voce vai colar os dois aqui.

PASSOS
}

autoriza_por_chave_propria() {
  mostra_passos_da_chave > /dev/tty

  local id secret
  id="$(le_do_tty 'Cole o ID do cliente')"
  secret="$(le_do_tty 'Cole a chave secreta do cliente' oculto)"
  id="$(printf '%s' "$id" | tr -d '[:space:]')"
  secret="$(printf '%s' "$secret" | tr -d '[:space:]')"
  if [[ -z "$id" || -z "$secret" ]]; then
    falha "os dois codigos sao obrigatorios"
    return 1
  fi
  autoriza_por_link "$id" "$secret" 1
}

configura_drive() {
  passo "Conectando o Google Drive"

  instala_rclone || return 1

  if remote_ja_existe && ((DRIVE_RECONFIGURAR == 0)); then
    if testa_remote; then
      feito "o remote '$DRIVE_REMOTE' ja esta conectado e respondendo"
      return 0
    fi
    aviso "o remote '$DRIVE_REMOTE' existe mas nao responde, vou refazer a autorizacao"
  fi

  if ! tem_terminal; then
    falha "a primeira autorizacao do Drive precisa de terminal, porque voce cola o token de volta"
    aviso "rode uma vez na mao: $NOME_SCRIPT --drive-configurar. Depois disso o envio roda sozinho no cron."
    return 1
  fi

  tem curl || { falha "preciso do curl para trocar o codigo pelo token"; return 1; }

  if ((DRIVE_CHAVE_PROPRIA)); then
    autoriza_por_chave_propria || return 1
  else
    autoriza_por_link "$CLIENTE_RCLONE" "$SEGREDO_RCLONE" 0 || return 1
  fi

  diz "testando a conexao"
  if testa_remote; then
    feito "Google Drive conectado"
    return 0
  fi
  falha "o remote foi gravado mas o Drive nao respondeu (veja $LOG)"
  aviso "se o token foi gerado com --drive-scope drive.file, use tambem --drive-escopo arquivos aqui"
  return 1
}

envia_para_drive() {
  local arquivo="$1"
  [[ -f "$arquivo" ]] || { falha "arquivo nao encontrado para enviar: $arquivo"; return 1; }

  passo "Enviando para o Google Drive"
  instala_rclone || return 1
  if ! remote_ja_existe || ! testa_remote; then
    configura_drive || return 1
  fi

  local pasta="$DRIVE_PASTA"
  [[ -n "$pasta" ]] || pasta="BackupCoolify/$MAQUINA"
  local destino="${DRIVE_REMOTE}:${pasta}"
  local nome; nome="$(basename "$arquivo")"

  diz "destino: $destino/$nome"
  diz "tamanho: $(legivel "$(stat -c%s "$arquivo")")"

  declare -a opcoes=(
    --config "$(arquivo_conf_rclone)"
    --drive-chunk-size 64M
    --retries 5 --low-level-retries 20
    --stats 15s --stats-one-line
    --log-level INFO --log-file "$LOG"
  )

  if rclone copyto "${opcoes[@]}" "$arquivo" "$destino/$nome"; then
    feito "pacote enviado"
  else
    falha "o envio do pacote falhou (veja $LOG)"
    return 1
  fi

  if [[ -f "$arquivo.sha256" ]]; then
    rclone copyto "${opcoes[@]}" "$arquivo.sha256" "$destino/$nome.sha256" \
      && feito "soma SHA256 enviada" \
      || aviso "a soma SHA256 nao foi enviada"
  fi

  # confere que o arquivo esta la com o tamanho certo
  local remoto local_bytes
  remoto="$(rclone size --config "$(arquivo_conf_rclone)" --json "$destino/$nome" 2>>"$LOG" \
            | sed -n 's/.*"bytes":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)" || remoto=""
  local_bytes="$(stat -c%s "$arquivo")"
  if [[ "$remoto" == "$local_bytes" ]]; then
    feito "conferido no Drive: $(legivel "$remoto")"
    DRIVE_ENVIADO="$destino/$nome"
  else
    falha "o tamanho no Drive ($remoto) nao bate com o local ($local_bytes)"
    return 1
  fi

  if ((DRIVE_MANTER > 0)); then
    diz "mantendo os $DRIVE_MANTER pacotes mais novos no Drive"
    local antigos n=0
    while IFS= read -r velho; do
      [[ -n "$velho" ]] || continue
      n=$((n + 1))
      if ((n > DRIVE_MANTER)); then
        rclone delete --config "$(arquivo_conf_rclone)" "$destino/$velho" >>"$LOG" 2>&1 \
          && diz "removido do Drive: $velho" \
          || aviso "nao consegui remover do Drive: $velho"
        rclone delete --config "$(arquivo_conf_rclone)" "$destino/$velho.sha256" >>"$LOG" 2>&1 || true
      fi
    done < <(rclone lsf --config "$(arquivo_conf_rclone)" "$destino" 2>>"$LOG" \
             | grep -E '^coolify-backup-.*\.tar\.gz(\.gpg|\.enc)?$' | sort -r || true)
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Modo --drive-configurar: so autoriza o Drive e sai, sem fazer backup
# ---------------------------------------------------------------------------
if ((DRIVE_SO_CONFIGURAR)); then
  if configura_drive; then
    printf '\n%s\n' "$(cor '1;32' 'Google Drive conectado.')"
    printf '  Daqui para frente basta acrescentar --google-drive ao backup:\n'
    printf '    sudo ./%s --google-drive\n\n' "$NOME_SCRIPT"
    exit 0
  fi
  morre "a autorizacao do Google Drive nao terminou"
fi

# ---------------------------------------------------------------------------
# Inventario
# ---------------------------------------------------------------------------
passo "Levantando o inventario da maquina"

mapfile -t CONTAINERS_TODOS < <(docker ps -aq 2>/dev/null || true)
mapfile -t CONTAINERS_ATIVOS < <(docker ps -q 2>/dev/null || true)
mapfile -t VOLUMES < <(docker volume ls -q 2>/dev/null || true)
feito "${#CONTAINERS_TODOS[@]} container(s), ${#CONTAINERS_ATIVOS[@]} de pe, ${#VOLUMES[@]} volume(s)"

# --- pastas de host montadas em container (bind mounts) --------------------
declare -a BINDS_BRUTOS=()
for id in ${CONTAINERS_TODOS[@]+"${CONTAINERS_TODOS[@]}"}; do
  while IFS=$'\t' read -r tipo origem _destino; do
    [[ "$tipo" == "bind" ]] || continue
    [[ -n "$origem" ]] || continue
    BINDS_BRUTOS+=("$origem")
  done < <(docker inspect --format '{{range .Mounts}}{{.Type}}{{"\t"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' "$id" 2>/dev/null || true)
done

ignora_bind() {
  local p="$1"
  case "$p" in
    /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 0 ;;
    /var/run/docker.sock|/var/lib/docker|/var/lib/docker/*) return 0 ;;
    /etc/localtime|/etc/timezone|/etc/hosts|/etc/hostname|/etc/resolv.conf) return 0 ;;
    /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*) return 0 ;;
    "$DIR_DADOS_COOLIFY"|"$DIR_DADOS_COOLIFY"/*) return 0 ;;   # ja vai inteiro
    "$DESTINO"|"$DESTINO"/*) return 0 ;;                        # nosso proprio destino
  esac
  [[ -e "$p" ]] || return 0
  return 1
}

declare -a BINDS=()
if ((${#BINDS_BRUTOS[@]})); then
  mapfile -t BINDS_UNICOS < <(printf '%s\n' "${BINDS_BRUTOS[@]}" | sed 's#/\+$##' | sort -u)
  for p in "${BINDS_UNICOS[@]}"; do
    ignora_bind "$p" && continue
    # descarta caminho que ja esta dentro de outro da lista
    filho=0
    for q in "${BINDS_UNICOS[@]}"; do
      [[ "$p" == "$q" ]] && continue
      if [[ "$p" == "$q"/* ]] && ! ignora_bind "$q"; then filho=1; break; fi
    done
    ((filho)) || BINDS+=("$p")
  done
fi
feito "${#BINDS[@]} pasta(s) de host montada(s) em container, fora de $DIR_DADOS_COOLIFY"

# --- bancos de dados -------------------------------------------------------
detecta_engine() {
  local id="$1" imagem
  imagem="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$imagem" in
    *postgres*|*postgis*|*pgvector*|*timescale*) echo postgres; return ;;
    *mariadb*)                                   echo mariadb;  return ;;
    *mysql*|*percona*)                           echo mysql;    return ;;
    *mongo*)                                     echo mongo;    return ;;
    *clickhouse*)                                echo clickhouse; return ;;
    *keydb*|*dragonfly*|*valkey*|*redis*)        echo redis;    return ;;
  esac
  # imagem com nome fora do padrao: decide pelas variaveis de ambiente
  [[ -n "$(env_do_container "$id" POSTGRES_USER)"            ]] && { echo postgres; return; }
  [[ -n "$(env_do_container "$id" POSTGRES_PASSWORD)"        ]] && { echo postgres; return; }
  [[ -n "$(env_do_container "$id" MARIADB_ROOT_PASSWORD)"    ]] && { echo mariadb;  return; }
  [[ -n "$(env_do_container "$id" MYSQL_ROOT_PASSWORD)"      ]] && { echo mysql;    return; }
  [[ -n "$(env_do_container "$id" MONGO_INITDB_ROOT_USERNAME)" ]] && { echo mongo;  return; }
  [[ -n "$(env_do_container "$id" REDIS_PASSWORD)"           ]] && { echo redis;    return; }
  echo ""
}

declare -a BANCO_ID=() BANCO_NOME=() BANCO_ENGINE=()
for id in ${CONTAINERS_ATIVOS[@]+"${CONTAINERS_ATIVOS[@]}"}; do
  eng="$(detecta_engine "$id")"
  [[ -n "$eng" ]] || continue
  BANCO_ID+=("$id"); BANCO_NOME+=("$(nome_do_container "$id")"); BANCO_ENGINE+=("$eng")
done
if ((${#BANCO_ID[@]})); then
  feito "${#BANCO_ID[@]} banco(s) de dados de pe:"
  for i in "${!BANCO_ID[@]}"; do printf '       %-45s %s\n' "${BANCO_NOME[$i]}" "${BANCO_ENGINE[$i]}"; done
else
  aviso "nenhum container de banco de dados em execucao foi reconhecido"
fi

# --- espaco em disco -------------------------------------------------------
passo "Medindo o espaco necessario"
TAM_COOLIFY=$(tamanho_de "$DIR_DADOS_COOLIFY")
TAM_BACKUPS_COOLIFY=$(tamanho_de "$DIR_DADOS_COOLIFY/backups")
TAM_VOLUMES=$(tamanho_de /var/lib/docker/volumes)
TAM_BINDS=0
for p in ${BINDS[@]+"${BINDS[@]}"}; do TAM_BINDS=$(( TAM_BINDS + $(tamanho_de "$p") )); done
((INCLUIR_BACKUPS_COOLIFY)) || TAM_COOLIFY=$(( TAM_COOLIFY - TAM_BACKUPS_COOLIFY ))
((TAM_COOLIFY > 0)) || TAM_COOLIFY=0
TAM_CRU=$(( TAM_COOLIFY + TAM_VOLUMES + TAM_BINDS ))

printf '       %-28s %s\n' "/data/coolify"            "$(legivel "$TAM_COOLIFY")"
((TAM_BACKUPS_COOLIFY > 0)) && printf '       %-28s %s%s\n' "  dos quais backups antigos" "$(legivel "$TAM_BACKUPS_COOLIFY")" "$( ((INCLUIR_BACKUPS_COOLIFY)) || printf ' (fora, --sem-backups)')"
printf '       %-28s %s\n' "volumes Docker"            "$(legivel "$TAM_VOLUMES")"
printf '       %-28s %s\n' "pastas de host em bind"    "$(legivel "$TAM_BINDS")"
printf '       %-28s %s\n' "total cru"                 "$(legivel "$TAM_CRU")"

PRECISA=$(( TAM_CRU * 8 / 10 + 1073741824 ))
LIVRE=$(espaco_livre "$DESTINO")
printf '       %-28s %s\n' "estimativa necessaria"     "$(legivel "$PRECISA")"
printf '       %-28s %s\n' "livre em $DESTINO"         "$(legivel "$LIVRE")"

if ((LIVRE < PRECISA)); then
  if ((FORCAR)); then
    aviso "espaco abaixo da estimativa, seguindo porque veio --forcar"
  else
    morre "espaco insuficiente em $DESTINO. Libere espaco, aponte outro disco com -d ou use --forcar"
  fi
fi

if ((SIMULAR)); then
  passo "Simulacao, nada foi gravado"
  printf '  modo .................. %s\n' "$MODO"
  printf '  pacote iria para ...... %s/%s.tar.gz\n' "$DESTINO" "$NOME_PACOTE"
  printf '  volumes ............... %s\n' "${#VOLUMES[@]}"
  printf '  binds ................. %s\n' "${#BINDS[@]}"
  printf '  bancos ................ %s\n' "${#BANCO_ID[@]}"
  printf '  imagens Docker ........ %s\n' "$( ((INCLUIR_IMAGENS)) && echo incluidas || echo 'fora (use --imagens)')"
  if ((ENVIAR_DRIVE)); then
    printf '  Google Drive .......... enviaria para %s:%s\n' "$DRIVE_REMOTE" "${DRIVE_PASTA:-BackupCoolify/$MAQUINA}"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Montagem do pacote
# ---------------------------------------------------------------------------
TRABALHO="$DESTINO/.trabalho-$CARIMBO/$NOME_PACOTE"
mkdir -p "$TRABALHO"/{00-meta/compose,01-coolify,02-bancos,03-volumes,04-binds,05-sistema}
((INCLUIR_IMAGENS)) && mkdir -p "$TRABALHO/06-imagens"
chmod 700 "$DESTINO/.trabalho-$CARIMBO"

# ---------------------------------------------------------------------------
# 00-meta: retrato do Docker
# ---------------------------------------------------------------------------
passo "Guardando o retrato do Docker"
META="$TRABALHO/00-meta"

docker version                         > "$META/docker-version.txt" 2>&1 || true
docker info                            > "$META/docker-info.txt" 2>&1 || true
docker ps -a --no-trunc                > "$META/containers.txt" 2>&1 || true
docker images --digests --no-trunc     > "$META/imagens.txt" 2>&1 || true
docker volume ls                       > "$META/volumes.txt" 2>&1 || true
docker network ls                      > "$META/redes.txt" 2>&1 || true
uname -a                               > "$META/uname.txt" 2>&1 || true

if ((${#CONTAINERS_TODOS[@]})); then
  docker inspect "${CONTAINERS_TODOS[@]}" > "$META/containers.json" 2>/dev/null || true
fi

# containers em formato simples, para o relatorio e para a restauracao
: > "$META/containers.tsv"
for id in ${CONTAINERS_TODOS[@]+"${CONTAINERS_TODOS[@]}"}; do
  docker inspect --format \
    '{{.Name}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.State.Status}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{index .Config.Labels "coolify.projectName"}}{{"\t"}}{{index .Config.Labels "coolify.resourceName"}}{{"\t"}}{{index .Config.Labels "coolify.type"}}' \
    "$id" 2>/dev/null | sed 's#^/##' >> "$META/containers.tsv" || true
done

# volumes com driver e etiquetas, para recriar igual na restauracao
: > "$META/volumes.tsv"
for v in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
  docker volume inspect --format \
    '{{.Name}}{{"\t"}}{{.Driver}}{{"\t"}}{{range $k,$x := .Labels}}{{$k}}={{$x}},{{end}}{{"\t"}}{{.Mountpoint}}' \
    "$v" 2>/dev/null >> "$META/volumes.tsv" || true
done

# redes com driver, sub-rede e etiquetas
: > "$META/redes.tsv"
while read -r rede; do
  [[ -n "$rede" ]] || continue
  case "$rede" in bridge|host|none) continue ;; esac
  docker network inspect --format \
    '{{.Name}}{{"\t"}}{{.Driver}}{{"\t"}}{{range .IPAM.Config}}{{.Subnet}}{{end}}{{"\t"}}{{range .IPAM.Config}}{{.Gateway}}{{end}}{{"\t"}}{{.Attachable}}{{"\t"}}{{.Internal}}{{"\t"}}{{range $k,$x := .Labels}}{{$k}}={{$x}},{{end}}' \
    "$rede" 2>/dev/null >> "$META/redes.tsv" || true
done < <(docker network ls --format '{{.Name}}' 2>/dev/null || true)

# arquivos compose que o Docker conhece e que moram fora de /data/coolify
: > "$META/compose.tsv"
for id in ${CONTAINERS_TODOS[@]+"${CONTAINERS_TODOS[@]}"}; do
  arquivos="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$id" 2>/dev/null || true)"
  [[ -n "$arquivos" && "$arquivos" != "<no value>" ]] || continue
  IFS=',' read -r -a lista <<< "$arquivos"
  for f in "${lista[@]}"; do
    [[ -f "$f" ]] || continue
    case "$f" in "$DIR_DADOS_COOLIFY"/*) continue ;; esac
    nome="$(slug "$f")"
    cp -p "$f" "$META/compose/$nome" 2>/dev/null || continue
    printf '%s\t%s\n' "$f" "$nome" >> "$META/compose.tsv"
  done
done
sort -u -o "$META/compose.tsv" "$META/compose.tsv" 2>/dev/null || true

# versao do Coolify: e o que a restauracao precisa instalar antes de tudo
VERSAO_COOLIFY=""
IMAGEM_COOLIFY="$(docker inspect --format '{{.Config.Image}}' coolify 2>/dev/null || true)"
[[ -n "$IMAGEM_COOLIFY" ]] && VERSAO_COOLIFY="${IMAGEM_COOLIFY##*:}"
[[ -z "$VERSAO_COOLIFY" && -f "$DIR_DADOS_COOLIFY/source/.env" ]] && \
  VERSAO_COOLIFY="$(awk -F= '/^[[:space:]]*(LATEST_)?VERSION=/{gsub(/"/,"",$2); print $2; exit}' "$DIR_DADOS_COOLIFY/source/.env" 2>/dev/null || true)"

# nome do volume onde mora o banco do painel. A restauracao precisa dele para
# saber se pode fazer o clone completo. Nao da para chutar "coolify-db": o nome
# depende de como o compose do instalador nomeia o volume naquela versao.
VOLUME_BANCO_PAINEL=""
while IFS=$'\t' read -r vnome vdest; do
  [[ -n "$vnome" ]] || continue
  case "$vdest" in
    /var/lib/postgresql*) VOLUME_BANCO_PAINEL="$vnome"; break ;;
  esac
  if [[ -z "$VOLUME_BANCO_PAINEL" ]]; then VOLUME_BANCO_PAINEL="$vnome"; fi
done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}{{end}}' coolify-db 2>/dev/null || true)
[[ -n "$VOLUME_BANCO_PAINEL" ]] && feito "volume do banco do painel: $VOLUME_BANCO_PAINEL"

{
  printf 'maquina=%s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'data=%s\n' "$(date -Is)"
  printf 'script=%s\n' "$VERSAO_SCRIPT"
  printf 'modo=%s\n' "$MODO"
  printf 'imagem_coolify=%s\n' "${IMAGEM_COOLIFY:-desconhecida}"
  printf 'versao_coolify=%s\n' "${VERSAO_COOLIFY:-desconhecida}"
  printf 'docker=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  printf 'arquitetura=%s\n' "$(uname -m)"
  printf 'ip_publico=%s\n' "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || echo '?')"
  printf 'volume_banco_painel=%s\n' "$VOLUME_BANCO_PAINEL"
  printf 'imagens_incluidas=%s\n' "$INCLUIR_IMAGENS"
  printf 'backups_coolify_incluidos=%s\n' "$INCLUIR_BACKUPS_COOLIFY"
} > "$META/info.txt"
feito "retrato guardado (Coolify ${VERSAO_COOLIFY:-?})"

# ---------------------------------------------------------------------------
# 02-bancos: dump logico, feito pela ferramenta de cada banco
# ---------------------------------------------------------------------------
passo "Dump logico dos bancos de dados"
DIR_BANCOS="$TRABALHO/02-bancos"
: > "$DIR_BANCOS/_bancos.tsv"
declare -a PRECISA_PARAR=()

registra_banco() {  # container, engine, metodo, arquivo, situacao
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$DIR_BANCOS/_bancos.tsv"
}

confere_dump() {  # arquivo, minimo de bytes
  local f="$1" minimo="${2:-200}"
  [[ -s "$f" ]] || return 1
  local t; t=$(stat -c%s "$f" 2>/dev/null || echo 0)
  (( t >= minimo ))
}

dump_postgres() {
  local id="$1" nome="$2" base="$3"
  local usuario senha script saida bd s2
  usuario="$(env_do_container "$id" POSTGRES_USER)"; [[ -n "$usuario" ]] || usuario=postgres
  senha="$(env_do_container "$id" POSTGRES_PASSWORD)"
  script="$(cat <<SH
command -v pg_dumpall >/dev/null 2>&1 || { echo "pg_dumpall ausente na imagem" >&2; exit 127; }
PGUSER=\$(printf '%s' '$(b64 "$usuario")' | base64 -d); export PGUSER
PGPASSWORD=\$(printf '%s' '$(b64 "$senha")' | base64 -d); export PGPASSWORD
exec pg_dumpall --clean --if-exists
SH
)"
  saida="$base/todos-os-bancos.sql.gz"
  if printf '%s' "$script" | roda_no_container "$id" 2>>"$LOG" | $COMPRESSOR > "$saida"; then
    if confere_dump "$saida" 300; then
      feito "$nome: pg_dumpall ($(legivel "$(stat -c%s "$saida")"))"
      registra_banco "$nome" postgres pg_dumpall "$(basename "$base")/todos-os-bancos.sql.gz" ok
      # para o banco interno do Coolify, guarda tambem o formato custom, que e
      # o que a documentacao oficial usa no pg_restore
      if [[ "$nome" == "coolify-db" ]]; then
        bd="$(env_do_container "$id" POSTGRES_DB)"; [[ -n "$bd" ]] || bd=coolify
        s2="$(cat <<SH
PGUSER=\$(printf '%s' '$(b64 "$usuario")' | base64 -d); export PGUSER
PGPASSWORD=\$(printf '%s' '$(b64 "$senha")' | base64 -d); export PGPASSWORD
BD=\$(printf '%s' '$(b64 "$bd")' | base64 -d)
exec pg_dump --format=custom --compress=9 "\$BD"
SH
)"
        if printf '%s' "$s2" | roda_no_container "$id" 2>>"$LOG" > "$base/coolify.dmp"; then
          feito "coolify-db: pg_dump custom ($(legivel "$(stat -c%s "$base/coolify.dmp")"))"
          registra_banco "$nome" postgres pg_dump_custom "$(basename "$base")/coolify.dmp" ok
        else
          rm -f "$base/coolify.dmp"
          aviso "coolify-db: o pg_dump em formato custom falhou, o pg_dumpall cobre"
        fi
      fi
      return 0
    fi
  fi
  rm -f "$saida"
  return 1
}

dump_mysql() {
  local id="$1" nome="$2" base="$3" engine="$4"
  local senha script saida
  senha="$(env_do_container "$id" MYSQL_ROOT_PASSWORD)"
  [[ -n "$senha" ]] || senha="$(env_do_container "$id" MARIADB_ROOT_PASSWORD)"
  script="$(cat <<SH
umask 077
CNF=/tmp/.bkp-cli.cnf
P=\$(printf '%s' '$(b64 "$senha")' | base64 -d)
printf '[client]\nuser=root\n' > "\$CNF"
printf 'password=%s\n' "\$P" >> "\$CNF"
DUMP=mysqldump
command -v mariadb-dump >/dev/null 2>&1 && DUMP=mariadb-dump
command -v "\$DUMP" >/dev/null 2>&1 || { echo "nenhum mysqldump ou mariadb-dump na imagem" >&2; rm -f "\$CNF"; exit 127; }
"\$DUMP" --defaults-extra-file="\$CNF" --all-databases --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4
st=\$?
rm -f "\$CNF"
exit \$st
SH
)"
  saida="$base/todos-os-bancos.sql.gz"
  if printf '%s' "$script" | roda_no_container "$id" 2>>"$LOG" | $COMPRESSOR > "$saida"; then
    if confere_dump "$saida" 300; then
      feito "$nome: dump de todos os bancos ($(legivel "$(stat -c%s "$saida")"))"
      registra_banco "$nome" "$engine" mysqldump "$(basename "$base")/todos-os-bancos.sql.gz" ok
      return 0
    fi
  fi
  rm -f "$saida"
  return 1
}

dump_mongo() {
  local id="$1" nome="$2" base="$3"
  local usuario senha script saida
  usuario="$(env_do_container "$id" MONGO_INITDB_ROOT_USERNAME)"
  senha="$(env_do_container "$id" MONGO_INITDB_ROOT_PASSWORD)"
  script="$(cat <<SH
command -v mongodump >/dev/null 2>&1 || { echo "mongodump nao vem nas imagens oficiais do MongoDB desde que as Database Tools passaram a ser pacote separado" >&2; exit 127; }
U=\$(printf '%s' '$(b64 "$usuario")' | base64 -d)
P=\$(printf '%s' '$(b64 "$senha")' | base64 -d)
if [ -n "\$U" ]; then
  exec mongodump --archive --gzip --quiet --username "\$U" --password "\$P" --authenticationDatabase admin
fi
exec mongodump --archive --gzip --quiet
SH
)"
  saida="$base/mongo.archive.gz"
  if printf '%s' "$script" | roda_no_container "$id" 2>>"$LOG" > "$saida"; then
    if confere_dump "$saida" 200; then
      feito "$nome: mongodump ($(legivel "$(stat -c%s "$saida")"))"
      registra_banco "$nome" mongo mongodump "$(basename "$base")/mongo.archive.gz" ok
      return 0
    fi
  fi
  rm -f "$saida"
  return 1
}

# Redis e familia: o SAVE grava um RDB consistente no proprio volume, que a
# copia de volume captura logo depois. Nao ha arquivo de dump separado.
salva_redis() {
  local id="$1" nome="$2"
  local senha script
  senha="$(env_do_container "$id" REDIS_PASSWORD)"
  [[ -n "$senha" ]] || senha="$(env_do_container "$id" REDIS_ARGS_PASSWORD)"
  script="$(cat <<SH
CLI=""
for c in redis-cli keydb-cli valkey-cli; do
  command -v "\$c" >/dev/null 2>&1 && { CLI="\$c"; break; }
done
[ -n "\$CLI" ] || { echo "nenhum cliente redis na imagem" >&2; exit 127; }
P=\$(printf '%s' '$(b64 "$senha")' | base64 -d)
if [ -n "\$P" ]; then set -- -a "\$P" --no-auth-warning; else set --; fi
"\$CLI" "\$@" SAVE >&2 || exit 1
if "\$CLI" "\$@" CONFIG GET appendonly 2>/dev/null | grep -qx yes; then
  "\$CLI" "\$@" BGREWRITEAOF >&2 || true
fi
exit 0
SH
)"
  if printf '%s' "$script" | roda_no_container "$id" >/dev/null 2>>"$LOG"; then
    return 0
  fi
  return 1
}

dump_clickhouse() {
  local id="$1" nome="$2" base="$3"
  local usuario senha script saida consulta
  usuario="$(env_do_container "$id" CLICKHOUSE_USER)"; [[ -n "$usuario" ]] || usuario=default
  senha="$(env_do_container "$id" CLICKHOUSE_PASSWORD)"
  consulta="$(cat <<'SQL'
SELECT concat(create_table_query, ';') FROM system.tables WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema') FORMAT TSVRaw
SQL
)"
  script="$(cat <<SH
command -v clickhouse-client >/dev/null 2>&1 || { echo "clickhouse-client ausente na imagem" >&2; exit 127; }
U=\$(printf '%s' '$(b64 "$usuario")' | base64 -d)
P=\$(printf '%s' '$(b64 "$senha")' | base64 -d)
Q=\$(printf '%s' '$(b64 "$consulta")' | base64 -d)
if [ -n "\$P" ]; then set -- --user "\$U" --password "\$P"; else set -- --user "\$U"; fi
clickhouse-client "\$@" --query "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
exec clickhouse-client "\$@" --query "\$Q"
SH
)"
  saida="$base/esquema.sql"
  if printf '%s' "$script" | roda_no_container "$id" 2>>"$LOG" > "$saida"; then
    feito "$nome: esquema do ClickHouse guardado (os dados vem na copia do volume)"
    registra_banco "$nome" clickhouse esquema_mais_volume "$(basename "$base")/esquema.sql" parcial
    return 1   # o dado em si depende do volume, entao pede parada curta
  fi
  rm -f "$saida"
  return 1
}

if ((${#BANCO_ID[@]} == 0)); then
  diz "nenhum banco para extrair"
else
  for i in "${!BANCO_ID[@]}"; do
    id="${BANCO_ID[$i]}"; nome="${BANCO_NOME[$i]}"; eng="${BANCO_ENGINE[$i]}"
    base="$DIR_BANCOS/$(slug "$nome")"
    mkdir -p "$base"
    ok=1
    case "$eng" in
      postgres)   dump_postgres "$id" "$nome" "$base" || ok=0 ;;
      mysql)      dump_mysql "$id" "$nome" "$base" mysql || ok=0 ;;
      mariadb)    dump_mysql "$id" "$nome" "$base" mariadb || ok=0 ;;
      mongo)      dump_mongo "$id" "$nome" "$base" || ok=0 ;;
      redis)      if salva_redis "$id" "$nome"; then
                    feito "$nome: SAVE executado, o RDB sai consistente na copia do volume"
                    registra_banco "$nome" redis save_mais_volume "-" ok
                  else ok=0; fi ;;
      clickhouse) dump_clickhouse "$id" "$nome" "$base" || ok=0 ;;
    esac
    # pasta vazia nao vai para o pacote (Redis grava no volume, nao em arquivo)
    rmdir "$base" 2>/dev/null || true
    if ((ok == 0)); then
      case "$MODO" in
        quente)
          falha "$nome ($eng): sem dump logico. Em --modo quente a copia sai a quente e pode vir inconsistente"
          registra_banco "$nome" "$eng" copia_a_quente "-" risco ;;
        *)
          aviso "$nome ($eng): sem dump logico, vou parar este container pelo tempo da copia do volume"
          PRECISA_PARAR+=("$id")
          registra_banco "$nome" "$eng" volume_com_parada "-" ok ;;
      esac
    fi
  done
fi

# ---------------------------------------------------------------------------
# Volumes: primeiro os que exigem parada curta, depois o resto
# ---------------------------------------------------------------------------
volumes_do_container() {
  docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$1" 2>/dev/null \
    | sed '/^$/d' || true
}

ja_pronto() {
  local v="$1" x
  for x in ${VOLUMES_PRONTOS[@]+"${VOLUMES_PRONTOS[@]}"}; do [[ "$x" == "$v" ]] && return 0; done
  return 1
}

copia_volume() {
  local vol="$1"
  # confere que o volume existe de verdade antes de criar arquivo no pacote
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    falha "volume $vol: o Docker nao reconhece este volume"
    return 1
  fi
  local arq="$TRABALHO/03-volumes/$(slug "$vol").tar.gz"
  local driver ponto
  driver="$(docker volume inspect -f '{{.Driver}}' "$vol" 2>/dev/null || echo '')"
  ponto="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || echo '')"
  if [[ "$driver" == "local" && -n "$ponto" && -d "$ponto" ]]; then
    tar_para_arquivo "$ponto" "$arq" || { falha "volume $vol: a copia falhou"; rm -f "$arq"; return 1; }
  else
    # nao da para ler pelo disco do host (driver de rede, ou ponto de montagem
    # fora do alcance): le por dentro de um container ajudante
    set +e
    docker run --rm -v "$vol":/vol:ro "$IMAGEM_AJUDANTE" \
      tar -cf - --numeric-owner -C /vol . 2>>"$LOG" | $COMPRESSOR > "$arq"
    local estados=("${PIPESTATUS[@]}")
    set -e
    if [[ "${estados[0]}" != 0 && "${estados[0]}" != 1 ]]; then
      falha "volume $vol: a copia pelo container ajudante falhou"; rm -f "$arq"; return 1
    fi
    aviso "volume $vol (driver '${driver:-?}') foi lido por container ajudante, sem ACL nem xattr"
  fi
  printf '%s\t%s\n' "$vol" "$(basename "$arq")" >> "$TRABALHO/03-volumes/_lista.tsv"
  VOLUMES_PRONTOS+=("$vol")
  return 0
}

para_container() {
  local id="$1" nome
  nome="$(nome_do_container "$id")"
  if docker stop "$id" >/dev/null 2>&1; then
    CONTAINERS_PARADOS+=("$nome")
    printf '%s\n' "$nome" >> "$ARQUIVO_PARADOS"
    return 0
  fi
  falha "nao consegui parar $nome"
  return 1
}

: > "$TRABALHO/03-volumes/_lista.tsv"

if ((${#PRECISA_PARAR[@]})); then
  passo "Parada curta dos bancos sem dump logico"
  for id in "${PRECISA_PARAR[@]}"; do
    nome="$(nome_do_container "$id")"
    mapfile -t vols < <(volumes_do_container "$id")
    diz "parando $nome (${#vols[@]} volume(s))"
    para_container "$id" || continue
    for v in ${vols[@]+"${vols[@]}"}; do
      ja_pronto "$v" && continue
      copia_volume "$v" && feito "volume $v copiado com o banco parado"
    done
    docker start "$id" >/dev/null 2>&1 && feito "$nome de pe outra vez" || falha "$nome nao voltou, confira no painel"
    # sai da lista de pendencias do trap
    novos=()
    for c in ${CONTAINERS_PARADOS[@]+"${CONTAINERS_PARADOS[@]}"}; do [[ "$c" == "$nome" ]] || novos+=("$c"); done
    CONTAINERS_PARADOS=(${novos[@]+"${novos[@]}"})
    grep -vxF "$nome" "$ARQUIVO_PARADOS" > "$ARQUIVO_PARADOS.tmp" 2>/dev/null || : > "$ARQUIVO_PARADOS.tmp"
    mv "$ARQUIVO_PARADOS.tmp" "$ARQUIVO_PARADOS"
  done
fi

if [[ "$MODO" == "frio" ]]; then
  passo "Modo frio: parando tudo antes de copiar"
  mapfile -t AINDA_DE_PE < <(docker ps -q 2>/dev/null || true)
  # para o Coolify primeiro, para o agendador nao religar nada no meio
  for n in coolify coolify-realtime coolify-sentinel; do
    if [[ -n "$(docker ps -q -f "name=^${n}\$" 2>/dev/null)" ]]; then
      para_container "$n" || true
    fi
  done
  for id in ${AINDA_DE_PE[@]+"${AINDA_DE_PE[@]}"}; do
    nome="$(nome_do_container "$id")"
    case "$nome" in coolify|coolify-realtime|coolify-sentinel) continue ;; esac
    para_container "$id" || true
  done
  feito "${#CONTAINERS_PARADOS[@]} container(s) parado(s), serao religados no fim"
fi

passo "Copiando os volumes Docker"
total_vol=0
for v in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
  ja_pronto "$v" && continue
  if copia_volume "$v"; then
    total_vol=$((total_vol + 1))
    printf '       %-60s %s\n' "$v" "$(legivel "$(stat -c%s "$TRABALHO/03-volumes/$(slug "$v").tar.gz" 2>/dev/null || echo 0)")"
  fi
done
feito "${#VOLUMES_PRONTOS[@]} volume(s) no pacote"

# ---------------------------------------------------------------------------
# 01-coolify: /data/coolify inteiro, mais a APP_KEY isolada
# ---------------------------------------------------------------------------
passo "Copiando $DIR_DADOS_COOLIFY"
if [[ -d "$DIR_DADOS_COOLIFY" ]]; then
  declare -a excecoes=()
  ((INCLUIR_BACKUPS_COOLIFY)) || excecoes+=(--exclude=./backups)
  st=0
  set +e
  tar "${FLAGS_TAR[@]}" ${excecoes[@]+"${excecoes[@]}"} -cf - -C "$DIR_DADOS_COOLIFY" . 2>>"$LOG" \
    | $COMPRESSOR > "$TRABALHO/01-coolify/data-coolify.tar.gz"
  estados=("${PIPESTATUS[@]}")
  set -e
  [[ "${estados[0]}" == 0 || "${estados[0]}" == 1 ]] || falha "a copia de $DIR_DADOS_COOLIFY falhou"
  feito "data-coolify.tar.gz ($(legivel "$(stat -c%s "$TRABALHO/01-coolify/data-coolify.tar.gz")"))"

  if [[ -f "$DIR_DADOS_COOLIFY/source/.env" ]]; then
    install -m 600 "$DIR_DADOS_COOLIFY/source/.env" "$TRABALHO/01-coolify/source.env"
    grep -E '^[[:space:]]*APP_KEY=' "$DIR_DADOS_COOLIFY/source/.env" > "$TRABALHO/01-coolify/APP_KEY.txt" 2>/dev/null || true
    chmod 600 "$TRABALHO/01-coolify/APP_KEY.txt" 2>/dev/null || true
    if [[ -s "$TRABALHO/01-coolify/APP_KEY.txt" ]]; then
      feito "APP_KEY isolada (sem ela o painel restaurado nao decifra nenhum segredo)"
    else
      falha "nao encontrei APP_KEY em $DIR_DADOS_COOLIFY/source/.env"
    fi
  else
    falha "$DIR_DADOS_COOLIFY/source/.env nao existe: a restauracao vai perder os segredos"
  fi

  # chave publica de cada chave privada do Coolify: a restauracao precisa
  # delas no authorized_keys para o painel conseguir falar com o servidor
  if [[ -d "$DIR_DADOS_COOLIFY/ssh/keys" ]] && tem ssh-keygen; then
    : > "$TRABALHO/01-coolify/chaves-publicas.txt"
    chmod 600 "$TRABALHO/01-coolify/chaves-publicas.txt"
    for k in "$DIR_DADOS_COOLIFY"/ssh/keys/*; do
      [[ -f "$k" ]] || continue
      case "$k" in *.pub) continue ;; esac
      ssh-keygen -y -f "$k" 2>/dev/null >> "$TRABALHO/01-coolify/chaves-publicas.txt" || true
    done
    n="$(conta "$TRABALHO/01-coolify/chaves-publicas.txt")"
    feito "$n chave(s) publica(s) derivada(s) das chaves do Coolify"
  fi
else
  falha "$DIR_DADOS_COOLIFY nao existe"
fi

# ---------------------------------------------------------------------------
# 04-binds: pastas de host montadas dentro de containers
# ---------------------------------------------------------------------------
passo "Copiando as pastas de host montadas em containers"
: > "$TRABALHO/04-binds/_mapa.tsv"
if ((${#BINDS[@]} == 0)); then
  diz "nenhuma, fora de $DIR_DADOS_COOLIFY"
else
  for p in "${BINDS[@]}"; do
    nome="$(slug "$p").tar.gz"
    if [[ -d "$p" ]]; then
      tar_para_arquivo "$p" "$TRABALHO/04-binds/$nome" || { falha "bind $p: copia falhou"; continue; }
      printf '%s\t%s\t%s\n' "$p" "$nome" "dir" >> "$TRABALHO/04-binds/_mapa.tsv"
    else
      # arquivo solto montado em container
      st=0
      set +e
      tar "${FLAGS_TAR[@]}" -cf - -C "$(dirname "$p")" "$(basename "$p")" 2>>"$LOG" | $COMPRESSOR > "$TRABALHO/04-binds/$nome"
      estados=("${PIPESTATUS[@]}")
      set -e
      [[ "${estados[0]}" == 0 || "${estados[0]}" == 1 ]] || { falha "bind $p: copia falhou"; continue; }
      printf '%s\t%s\t%s\n' "$p" "$nome" "arquivo" >> "$TRABALHO/04-binds/_mapa.tsv"
    fi
    printf '       %-60s %s\n' "$p" "$(legivel "$(stat -c%s "$TRABALHO/04-binds/$nome" 2>/dev/null || echo 0)")"
  done
fi

# ---------------------------------------------------------------------------
# 05-sistema: o que esta fora do Docker e faz o servidor ser o que e
# ---------------------------------------------------------------------------
passo "Copiando a configuracao do sistema"
SIS="$TRABALHO/05-sistema"

copia_se_tem() { [[ -e "$1" ]] && install -D -m 600 "$1" "$SIS/$2" 2>/dev/null && return 0; return 1; }

copia_se_tem /etc/docker/daemon.json       etc-docker-daemon.json && feito "daemon.json"
copia_se_tem /etc/hosts                    etc-hosts || true
copia_se_tem /etc/hostname                 etc-hostname || true
copia_se_tem /etc/fstab                    etc-fstab || true
copia_se_tem /etc/os-release               etc-os-release || true
copia_se_tem /root/.ssh/authorized_keys    root-authorized_keys && feito "authorized_keys do root"
copia_se_tem /root/.ssh/known_hosts        root-known_hosts || true
copia_se_tem /etc/timezone                 etc-timezone || true

{ crontab -l 2>/dev/null || true; } > "$SIS/crontab-root.txt"
[[ -s "$SIS/crontab-root.txt" ]] || rm -f "$SIS/crontab-root.txt"
for d in /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron; do
  [[ -d "$d" ]] || continue
  tar_para_arquivo "$d" "$SIS/$(slug "$d").tar.gz" >/dev/null 2>&1 || true
done

{ ip -o addr 2>/dev/null || true; echo; ip route 2>/dev/null || true; } > "$SIS/rede.txt"
{ ufw status verbose 2>/dev/null || true; } > "$SIS/ufw.txt"
[[ -s "$SIS/ufw.txt" ]] || rm -f "$SIS/ufw.txt"
{ iptables-save 2>/dev/null || true; } > "$SIS/iptables.txt"
[[ -s "$SIS/iptables.txt" ]] || rm -f "$SIS/iptables.txt"
{ df -hT 2>/dev/null || true; } > "$SIS/discos.txt"
{ free -h 2>/dev/null || true; nproc 2>/dev/null || true; } > "$SIS/recursos.txt"
if tem dpkg; then dpkg -l > "$SIS/pacotes-dpkg.txt" 2>/dev/null || true
elif tem rpm; then rpm -qa > "$SIS/pacotes-rpm.txt" 2>/dev/null || true; fi
if tem systemctl; then systemctl list-unit-files --state=enabled > "$SIS/servicos-habilitados.txt" 2>/dev/null || true; fi
feito "configuracao do sistema guardada"

# ---------------------------------------------------------------------------
# 06-imagens (opcional)
# ---------------------------------------------------------------------------
if ((INCLUIR_IMAGENS)); then
  passo "Exportando as imagens Docker (isso demora e pesa)"
  mapfile -t IMGS < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort -u || true)
  if ((${#IMGS[@]})); then
    printf '%s\n' "${IMGS[@]}" > "$TRABALHO/06-imagens/_lista.txt"
    if docker save "${IMGS[@]}" 2>>"$LOG" | $COMPRESSOR > "$TRABALHO/06-imagens/imagens.tar.gz"; then
      feito "${#IMGS[@]} imagem(ns) ($(legivel "$(stat -c%s "$TRABALHO/06-imagens/imagens.tar.gz")"))"
    else
      falha "docker save falhou"; rm -f "$TRABALHO/06-imagens/imagens.tar.gz"
    fi
  else
    aviso "nenhuma imagem com tag para exportar"
  fi
fi

# ---------------------------------------------------------------------------
# Religa o que foi parado no modo frio, antes de fechar o pacote
# ---------------------------------------------------------------------------
if [[ "$MODO" == "frio" ]]; then
  passo "Religando o servidor"
  religa_containers
  feito "containers de volta"
fi

# ---------------------------------------------------------------------------
# RESTAURAR.md, manifesto e somas de conferencia
# ---------------------------------------------------------------------------
passo "Escrevendo o roteiro de restauracao"

VERSAO_PARA_INSTALAR="${VERSAO_COOLIFY:-}"
LISTA_BANCOS="$(awk -F'\t' '{printf "| %s | %s | %s | %s |\n", $1, $2, $3, $5}' "$DIR_BANCOS/_bancos.tsv" 2>/dev/null || true)"
QTD_VOLUMES="$(conta "$TRABALHO/03-volumes/_lista.tsv")"
QTD_BINDS="$(conta "$TRABALHO/04-binds/_mapa.tsv")"
# conta container de banco, nao linha: o coolify-db gera duas linhas, porque
# sai em pg_dumpall e tambem no formato custom do pg_restore
QTD_BANCOS="$(awk -F'\t' 'NF{v[$1]=1} END{print length(v)}' "$DIR_BANCOS/_bancos.tsv" 2>/dev/null || echo 0)"

cat > "$TRABALHO/RESTAURAR.md" <<CABECALHO
# Restaurar este backup em outro servidor

Pacote gerado em $(date '+%d/%m/%Y as %H:%M') a partir de \`$(hostname -f 2>/dev/null || hostname)\`.

| Item | Valor |
|---|---|
| Versao do Coolify na origem | \`${VERSAO_COOLIFY:-desconhecida}\` |
| Imagem do Coolify | \`${IMAGEM_COOLIFY:-desconhecida}\` |
| Arquitetura | \`$(uname -m)\` |
| Volumes Docker no pacote | $QTD_VOLUMES |
| Pastas de host no pacote | $QTD_BINDS |
| Imagens Docker no pacote | $( ((INCLUIR_IMAGENS)) && echo sim || echo nao ) |

## Caminho curto

No servidor novo, com Docker instalado e o pacote copiado para la:

\`\`\`bash
sudo ./restaurar-coolify.sh --arquivo $NOME_PACOTE.tar.gz
\`\`\`

O script de restauracao faz, nesta ordem: confere o pacote, instala o Coolify na
mesma versao da origem se ele nao estiver la, para a pilha do painel, devolve
\`/data/coolify\`, acerta a APP_KEY no \`.env\`, recria redes e volumes, devolve
as pastas de host, restaura o banco interno do Coolify, publica as chaves SSH no
\`authorized_keys\` e sobe os recursos a partir dos compose que o Coolify
escreveu. No fim ele lista o que subiu e o que ficou faltando.

## Por que a APP_KEY e o item mais importante

O Coolify cifra senha, token e chave privada antes de gravar no banco. A chave
dessa cifra e a \`APP_KEY\` de \`/data/coolify/source/.env\`, e ela nao entra no
dump do banco. Restaurar o banco com outra APP_KEY devolve um painel que abre e
nao consegue ler nenhum segredo.

Neste pacote ela esta em \`01-coolify/APP_KEY.txt\` e o \`.env\` completo da
origem esta em \`01-coolify/source.env\`.

## Bancos de dados

| Container | Motor | Como foi guardado | Situacao |
|---|---|---|---|
$LISTA_BANCOS

Como ler a coluna do meio:

- \`pg_dumpall\`, \`mysqldump\`, \`mongodump\`: dump logico consistente, feito pela
  ferramenta do proprio banco com o servico no ar.
- \`pg_dump_custom\`: dump do banco interno do Coolify no formato que o
  \`pg_restore\` da documentacao oficial espera.
- \`save_mais_volume\`: Redis e familia. O \`SAVE\` gravou o RDB antes da copia do
  volume, entao o dado esta no volume, consistente.
- \`volume_com_parada\`: o container foi parado pelo tempo da copia do volume.
  Consistente, sem dump separado.
- \`esquema_mais_volume\`: ClickHouse. O esquema esta em arquivo e os dados no
  volume.
- \`copia_a_quente\`: risco. Rodou em \`--modo quente\` sem ferramenta de dump na
  imagem. Confira este banco depois de restaurar.

## Restauracao manual, se preferir ir passo a passo

CABECALHO

cat >> "$TRABALHO/RESTAURAR.md" <<'MANUAL'
```bash
# 1. Instale o Coolify na MESMA versao da origem
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash -s VERSAO_AQUI

# 2. Abra o pacote
tar xzf coolify-backup-*.tar.gz && cd coolify-backup-*

# 3. Pare o painel, deixando o banco de pe
docker stop coolify coolify-realtime coolify-redis

# 4. Devolva /data/coolify (menos source/, que pertence ao instalador)
mkdir -p /tmp/dc && tar xzf 01-coolify/data-coolify.tar.gz -C /tmp/dc --numeric-owner
rsync -aHAX --numeric-ids --exclude 'source/' /tmp/dc/ /data/coolify/

# 5. Acerte a APP_KEY no .env do servidor novo
grep APP_KEY 01-coolify/APP_KEY.txt         # valor da origem
nano /data/coolify/source/.env              # substitua a linha APP_KEY=

# 6. Volumes
while IFS=$'\t' read -r vol arq; do
  docker volume create "$vol" >/dev/null
  ponto=$(docker volume inspect -f '{{.Mountpoint}}' "$vol")
  tar xzf "03-volumes/$arq" -C "$ponto" --numeric-owner
done < 03-volumes/_lista.tsv

# 7. Pastas de host
while IFS=$'\t' read -r caminho arq tipo; do
  mkdir -p "$caminho"
  tar xzf "04-binds/$arq" -C "$caminho" --numeric-owner
done < 04-binds/_mapa.tsv

# 8. Banco interno do Coolify
docker exec -i coolify-db pg_restore --clean --if-exists --no-owner --no-acl \
  --username coolify --dbname coolify < 02-bancos/coolify-db/coolify.dmp

# 9. Publique as chaves do Coolify no authorized_keys do root
cat 01-coolify/chaves-publicas.txt >> /root/.ssh/authorized_keys
sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys

# 10. Suba o painel outra vez
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash -s VERSAO_AQUI
```

## Depois de restaurar, confira nesta ordem

1. O painel abre e mostra os projetos, sem erro de decifragem.
2. Em Servers > localhost, o botao de validar passa.
3. Cada banco de dados aparece como de pe e aceita conexao.
4. Uma aplicacao abre no dominio dela, com os arquivos de usuario no lugar.
5. Se o IP mudou, acerte o DNS e os dominios que usavam IP no lugar de nome.

## Pontos que costumam morder

- **Versao diferente do Coolify.** Restaurar um dump de banco em uma versao mais
  nova funciona na maioria dos casos porque as migracoes rodam, mas o caminho
  seguro e instalar a mesma versao, restaurar, e so depois atualizar pelo painel.
- **Aplicacao construida no servidor.** Imagem criada por build local nao existe
  na maquina nova. Com `--imagens` no backup ela vem no pacote. Sem isso, basta
  um deploy pelo painel, que reconstroi e reaproveita o volume de dados.
- **Permissao de pasta de servico.** O instalador do Coolify faz `chown`
  recursivo em `/data/coolify` a cada instalacao. Se um servico usa UID proprio,
  confira o dono da pasta dele depois de restaurar.
- **Dois servidores no ar ao mesmo tempo.** Se a origem continuar de pe com o
  mesmo banco restaurado em outra maquina, as duas instancias vao tentar
  gerenciar os mesmos recursos. Desligue uma.
MANUAL

sed -i "s/VERSAO_AQUI/${VERSAO_PARA_INSTALAR:-latest}/g" "$TRABALHO/RESTAURAR.md" 2>/dev/null || true
feito "RESTAURAR.md"

# manifesto
{
  echo "PACOTE ......... $NOME_PACOTE"
  echo "ORIGEM ......... $(hostname -f 2>/dev/null || hostname)"
  echo "DATA ........... $(date -Is)"
  echo "SCRIPT ......... $NOME_SCRIPT v$VERSAO_SCRIPT"
  echo "MODO ........... $MODO"
  echo "COOLIFY ........ ${VERSAO_COOLIFY:-desconhecida}"
  echo "DOCKER ......... $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  echo "ARQUITETURA .... $(uname -m)"
  echo
  echo "CONTEUDO"
  echo "  volumes Docker ....... $QTD_VOLUMES"
  echo "  pastas de host ....... $QTD_BINDS"
  echo "  bancos de dados ...... $QTD_BANCOS"
  echo "  containers no retrato  ${#CONTAINERS_TODOS[@]}"
  echo "  imagens Docker ....... $( ((INCLUIR_IMAGENS)) && echo incluidas || echo 'nao incluidas' )"
  echo "  backups do Coolify ... $( ((INCLUIR_BACKUPS_COOLIFY)) && echo incluidos || echo 'nao incluidos' )"
  echo
  echo "AVISOS (${#AVISOS[@]})"
  for a in ${AVISOS[@]+"${AVISOS[@]}"}; do echo "  - $a"; done
  echo
  echo "FALHAS (${#ERROS[@]})"
  for e in ${ERROS[@]+"${ERROS[@]}"}; do echo "  - $e"; done
  echo
  echo "ESTE PACOTE CONTEM SEGREDO: APP_KEY, senha de banco e chave SSH privada."
} > "$TRABALHO/MANIFESTO.txt"

passo "Calculando as somas de conferencia"
( cd "$TRABALHO" && find . -type f ! -name CHECKSUMS.sha256 -print0 | sort -z \
    | xargs -0 sha256sum > CHECKSUMS.sha256 ) 2>>"$LOG" || aviso "nao consegui gerar todos os checksums"
feito "CHECKSUMS.sha256 com $(conta "$TRABALHO/CHECKSUMS.sha256") arquivo(s)"

cp -p "$LOG" "$TRABALHO/backup.log" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Arquivo unico
# ---------------------------------------------------------------------------
passo "Fechando o arquivo unico"
ARQUIVO_FINAL="$DESTINO/$NOME_PACOTE.tar.gz"
# compressao 1 aqui porque o conteudo ja vem comprimido por dentro
st=0
set +e
tar --numeric-owner -cf - -C "$(dirname "$TRABALHO")" "$(basename "$TRABALHO")" 2>>"$LOG" \
  | gzip -1 > "$ARQUIVO_FINAL"
estados=("${PIPESTATUS[@]}")
set -e
[[ "${estados[0]}" == 0 || "${estados[0]}" == 1 ]] || morre "nao consegui montar o arquivo final"
[[ "${estados[1]:-0}" == 0 ]] || morre "a compressao do arquivo final falhou"
feito "$(basename "$ARQUIVO_FINAL") ($(legivel "$(stat -c%s "$ARQUIVO_FINAL")"))"

passo "Conferindo o arquivo gerado"
gzip -t "$ARQUIVO_FINAL" 2>>"$LOG" || morre "o arquivo final nao passou no teste de gzip"
feito "gzip -t passou"
tar -tzf "$ARQUIVO_FINAL" > /dev/null 2>>"$LOG" || morre "o arquivo final nao passou no teste de tar"
feito "tar -tzf passou"
SHA="$(sha256sum "$ARQUIVO_FINAL" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$ARQUIVO_FINAL")" > "$ARQUIVO_FINAL.sha256"
feito "SHA256 calculado"

if ((CIFRAR)); then
  passo "Cifrando o pacote"
  if tem gpg; then
    if [[ -n "$ARQUIVO_SENHA" ]]; then
      gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "$ARQUIVO_SENHA" \
        -o "$ARQUIVO_FINAL.gpg" "$ARQUIVO_FINAL" || morre "a cifra falhou"
    else
      gpg --symmetric --cipher-algo AES256 -o "$ARQUIVO_FINAL.gpg" "$ARQUIVO_FINAL" || morre "a cifra falhou"
    fi
    rm -f "$ARQUIVO_FINAL"
    ARQUIVO_FINAL="$ARQUIVO_FINAL.gpg"
  else
    openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "$ARQUIVO_FINAL" -out "$ARQUIVO_FINAL.enc" \
      ${ARQUIVO_SENHA:+-pass "file:$ARQUIVO_SENHA"} || morre "a cifra falhou"
    rm -f "$ARQUIVO_FINAL"
    ARQUIVO_FINAL="$ARQUIVO_FINAL.enc"
  fi
  SHA="$(sha256sum "$ARQUIVO_FINAL" | awk '{print $1}')"
  printf '%s  %s\n' "$SHA" "$(basename "$ARQUIVO_FINAL")" > "$ARQUIVO_FINAL.sha256"
  feito "pacote cifrado: $(basename "$ARQUIVO_FINAL")"
fi

chmod 600 "$ARQUIVO_FINAL" "$ARQUIVO_FINAL.sha256" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Envio para o Google Drive
# ---------------------------------------------------------------------------
if ((ENVIAR_DRIVE)); then
  envia_para_drive "$ARQUIVO_FINAL" \
    || falha "o envio para o Google Drive nao terminou. O pacote continua aqui: $ARQUIVO_FINAL"
fi

# ---------------------------------------------------------------------------
# Relatorio
# ---------------------------------------------------------------------------
rm -rf "$(dirname "$TRABALHO")"
TRABALHO=""
[[ -f "$ARQUIVO_PARADOS" ]] && rm -f "$ARQUIVO_PARADOS"
DURACAO=$(( $(date +%s) - INICIO_EPOCH ))

printf '\n%s\n' "$(cor '1;32' '============================ BACKUP CONCLUIDO ============================')"
printf '  Arquivo ....... %s\n' "$ARQUIVO_FINAL"
printf '  Tamanho ....... %s\n' "$(legivel "$(stat -c%s "$ARQUIVO_FINAL")")"
printf '  SHA256 ........ %s\n' "$SHA"
if ((ENVIAR_DRIVE)); then
  if [[ -n "$DRIVE_ENVIADO" ]]; then
    printf '  Google Drive .. %s\n' "$DRIVE_ENVIADO"
  else
    printf '  Google Drive .. %s\n' "nao enviado, veja as falhas abaixo"
  fi
fi
printf '  Duracao ....... %dm %ds\n' $((DURACAO/60)) $((DURACAO%60))
printf '  Modo .......... %s\n' "$MODO"
printf '  Volumes ....... %s\n' "$QTD_VOLUMES"
printf '  Pastas host ... %s\n' "$QTD_BINDS"
printf '  Bancos ........ %s\n' "$QTD_BANCOS"
printf '  Avisos ........ %s\n' "${#AVISOS[@]}"
printf '  Falhas ........ %s\n' "${#ERROS[@]}"

if ((${#ERROS[@]})); then
  printf '\n%s\n' "$(cor '1;31' 'FALHAS QUE PRECISAM DE OLHO:')"
  for e in "${ERROS[@]}"; do printf '  - %s\n' "$e"; done
fi
if ((${#AVISOS[@]})); then
  printf '\n%s\n' "$(cor '1;33' 'AVISOS:')"
  for a in "${AVISOS[@]}"; do printf '  - %s\n' "$a"; done
fi

printf '\n  Para baixar, de outra maquina:\n'
printf '    scp root@%s:%s .\n' "$(hostname -I 2>/dev/null | awk '{print $1}' || echo SEU_IP)" "$ARQUIVO_FINAL"
printf '\n  Para restaurar no servidor novo:\n'
printf '    sudo ./restaurar-coolify.sh --arquivo %s\n' "$(basename "$ARQUIVO_FINAL")"
printf '\n  %s\n\n' "$(cor '1;33' 'O pacote tem APP_KEY, senha de banco e chave SSH privada. Guarde como segredo.')"

if ((${#ERROS[@]})); then exit 2; fi
exit 0
