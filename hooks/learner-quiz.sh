#!/bin/sh
# Part of "learning mode" (paired with learner-record-edit.sh).
#
# Stop hook: when the session has edited meaningful source files, blocks the stop
# once and asks Claude to quiz the user about the code/architecture at their level.
# Opt-in via .claude/learner.local.json:
#   { "level": "junior" }          # or "intermediaire" / "senior"
#
# Anti-loop: skips when stop_hook_active is true (already in the quiz
# continuation) so Claude actually waits for the user's answer instead of
# looping. Wired as a Stop hook; see .claude/settings.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
LEVEL_FILE="$PROJECT_DIR/.claude/learner.local.json"

# Opt-in only: needs a declared level.
[ -f "$LEVEL_FILE" ] || exit 0
LEVEL=$(jq -r '.level // empty' "$LEVEL_FILE" 2>/dev/null)
[ -n "$LEVEL" ] || exit 0

# Mechanical trou guardrail (runs regardless of the enabled switch): a fill-in
# exercise injects distinctive `// LEARNER-TODO:` markers into real source. If any
# survive — e.g. the session died mid-exercise — block and force a restore before
# anything else, so we never leave the working tree broken.
if command -v git >/dev/null 2>&1; then
  HOLES=$(cd "$PROJECT_DIR" 2>/dev/null && git grep -l 'LEARNER-TODO' 2>/dev/null | head -n 20 | tr '\n' ' ')
  if [ -n "$HOLES" ]; then
    GR="🎓 Mode apprentissage — un exercice « fonction à trou » n'a pas été restauré : ces fichiers contiennent encore des marqueurs // LEARNER-TODO : $HOLES. AVANT toute autre chose, restaure la version correcte (git diff / diff de branche), retire TOUS les // LEARNER-TODO, et vérifie que ça compile/lint/teste. Ne termine pas tant qu'il en reste."
    jq -n --arg r "$GR" '{decision:"block", reason:$r}' 2>/dev/null \
      || printf '{"decision":"block","reason":"Restore files still containing // LEARNER-TODO markers before finishing: %s"}\n' "$HOLES"
    exit 0
  fi
fi

# Master switch: enabled defaults to true; only an explicit false turns it off.
# NB: use bare .enabled, not `.enabled // true` — jq's // treats false as absent,
# so `false // true` would wrongly yield true and the switch would never work.
ENABLED=$(jq -r '.enabled' "$LEVEL_FILE" 2>/dev/null)
[ "$ENABLED" = "false" ] && exit 0

DATA=$(cat)

# Don't re-block while already continuing from this hook, else Claude never gets
# to wait for the user and we risk an infinite stop loop.
ACTIVE=$(printf '%s' "$DATA" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
[ -n "$SID" ] || exit 0

STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
[ -s "$STATE" ] || exit 0

SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
COUNT="${TMPDIR:-/tmp}/claude-learner-${SID}.count"

# Every Nth quiz is a session-wide synthesis instead of a granular question.
RECAP_EVERY=$(jq -r '.recapEvery // 3' "$LEVEL_FILE" 2>/dev/null)
case "$RECAP_EVERY" in ''|*[!0-9]*) RECAP_EVERY=3 ;; esac
[ "$RECAP_EVERY" -lt 1 ] && RECAP_EVERY=1

# Bump the per-session quiz counter.
N=$(cat "$COUNT" 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1)); echo "$N" > "$COUNT"

# Language of the question (fr default).
LANGCODE=$(jq -r '.language // "fr"' "$LEVEL_FILE" 2>/dev/null)
case "$LANGCODE" in en|EN|en-*) LANGNAME="anglais" ;; *) LANGNAME="français" ;; esac
LANG_DIRECTIVE="Formule la question à l'utilisateur en $LANGNAME."

# Allowed question formats (array or "auto"; auto/absent = all formats).
STYLES=$(jq -r 'if (.questionStyles|type)=="array" then (.questionStyles|join(",")) else (.questionStyles // "auto") end' "$LEVEL_FILE" 2>/dev/null)
case "$STYLES" in ''|null|auto|AUTO) STYLES="auto" ;; esac

# Number of blanks (// TODO holes) left for the dev in an interactive fill-in exercise.
TROU_BLANKS=$(jq -r '.trouBlanks // 2' "$LEVEL_FILE" 2>/dev/null)
case "$TROU_BLANKS" in ''|*[!0-9]*) TROU_BLANKS=2 ;; esac
[ "$TROU_BLANKS" -lt 1 ] && TROU_BLANKS=1

# The "trou" (fill-in) format is INTERACTIVE and happens in the real source file:
# Claude removes part of a real function and the dev writes it back, in-editor.
TROU_DESC="exercice « fonction à trou » INTERACTIF, écrit dans le VRAI fichier source (pas en chat) : choisis UNE fonction courte parmi les fichiers modifiés ci-dessus, puis édite ce fichier pour remplacer $TROU_BLANKS endroit(s) clé(s) de son corps par des commentaires « // LEARNER-TODO: <indice décrivant ce qui doit aller là> » (garde la signature et le code alentour intacts). GARDE-FOU : avant de percer les trous, mémorise la version correcte (elle est dans git / le diff) ; ne perce QUE cette fonction. Annonce au dev le fichier + la fonction, demande-lui d'écrire le code manquant DIRECTEMENT dans le fichier, puis ATTENDS sa réponse — n'écris pas le code à sa place. Quand il a fini (ou dit « skip »), compare à l'implémentation correcte, donne un retour bref (correct / à corriger), puis RESTAURE une version correcte et VÉRIFIE qu'elle est valide (compile/lint/test ciblé selon le langage). NE TERMINE JAMAIS le tour en laissant le fichier cassé ou avec des // LEARNER-TODO résiduels (un garde-fou automatique bloquera la fin de session tant qu'il en reste)."

if [ "$STYLES" = "auto" ]; then
  STYLE_DIRECTIVE="Varie le format d'une fois sur l'autre, choisis le plus pertinent :
- une question sur ce que fait une fonction précise du code modifié ;
- une question d'architecture (dans quel module / dossier / couche ça vit, et pourquoi ce choix) ;
- un $TROU_DESC"
else
  STYLE_DIRECTIVE="Utilise UNIQUEMENT ce(s) format(s) : $STYLES.
Légende : code = question sur ce que fait une fonction du code modifié ; archi = question d'architecture (module / dossier / couche et pourquoi) ; trou = $TROU_DESC"
fi

# Two-file learning memory. TODAY is supplied so the recap history can be dated.
TODAY=$(date +%F 2>/dev/null)
PROGRESS_DIRECTIVE="Deux fichiers d'apprentissage (à créer s'ils manquent) :
1. .claude/learner-memory.md — MÉMOIRE DE TRAVAIL du quiz (points faibles ouverts, un par ligne « - [Domaine] concept — vu: date »). LIS-la AVANT de choisir la question et privilégie un point encore ouvert s'il est pertinent (répétition espacée). Mets-la à jour : ajoute une ligne si l'utilisateur rate/hésite, retire la ligne s'il maîtrise. C'est le SEUL fichier qui pilote le choix des questions.
2. .claude/learner-recap.md — TABLEAU DE BORD LISIBLE pour le dev (sections « À améliorer » et « Acquis » regroupées par domaine : Code, Architecture, Tests, CI/Build, Données & DB, Intégrations ; puis « Historique des sessions » : tableau Date|Domaine|Style|Verdict|Note). Tu l'ÉCRIS/mets à jour seulement, tu ne le LIS JAMAIS pour choisir une question. IMPORTANT — dans « À améliorer »/« Acquis », formule des THÈMES DE COMPÉTENCE GÉNÉRAUX (ex. « Accès aux données et performance des requêtes », « Gestion des erreurs et exceptions », « Découpage en couches et responsabilités des modules », « Structure et couverture des tests »), JAMAIS le concept précis d'une seule question. Regroupe plusieurs points faibles proches sous UN même thème ; vise une poignée de thèmes par domaine, pas une liste qui gonfle. Le détail fin reste dans learner-memory.md ; le recap est la vue d'ensemble « sur quoi je dois globalement monter en compétence ». Seul « Historique des sessions » garde le détail par question.
APRÈS la réponse de l'utilisateur, mets à jour les DEUX : dans learner-memory.md (ajout/retrait du point faible précis), et dans learner-recap.md (ajoute une ligne d'historique « | $TODAY | <domaine> | <code/archi/trou> | <✅ ok / ⚠️ à revoir / ⏭️ skip> | <note courte> | » + rattache le point au THÈME GÉNÉRAL correspondant sous « À améliorer » ou « Acquis », en créant le thème seulement s'il n'existe pas déjà). Garde tout concis."

if [ $((N % RECAP_EVERY)) -eq 0 ] && [ -s "$SESSION" ]; then
  # Synthesis: step back over everything touched this session.
  FILES=$(sort -u "$SESSION" | head -n 40 | tr '\n' ' ')
  REASON="🎓 Mode apprentissage — point de synthèse (niveau : $LEVEL).

L'utilisateur code avec toi depuis un moment ; vérifie qu'il garde la vue d'ensemble. Pose UNE seule question de SYNTHÈSE sur l'ensemble du travail de la session, pas sur un détail.

Ensemble des fichiers touchés cette session : $FILES

Choisis l'angle le plus utile à son niveau ($LEVEL) :
- comment les morceaux édités s'articulent (flux de données, appels entre couches / modules / composants) ;
- quelle responsabilité vit dans quel module / dossier et pourquoi ;
- s'il devait réexpliquer à un collègue ce qui a été construit dans cette session, quel en serait le résumé en 2-3 phrases.

$PROGRESS_DIRECTIVE

$LANG_DIRECTIVE
Pose la question puis ATTENDS sa réponse — ne réponds pas à sa place. « skip » pour passer. Après sa réponse, corrige/complète brièvement sa vue d'ensemble avant de continuer."
else
  # Granular: focus on the code edited since the last quiz.
  FILES=$(sort -u "$STATE" | head -n 20 | tr '\n' ' ')
  REASON="🎓 Mode apprentissage actif (niveau de l'utilisateur : $LEVEL).

Avant de terminer, pose UNE seule question courte à l'utilisateur pour vérifier qu'il a compris le travail qui vient d'être fait. Adapte la difficulté à son niveau ($LEVEL).

Fichiers modifiés depuis la dernière question : $FILES

$STYLE_DIRECTIVE

$PROGRESS_DIRECTIVE

$LANG_DIRECTIVE
Pose la question puis ATTENDS la réponse de l'utilisateur — ne réponds pas à sa place. S'il répond « skip », enchaîne normalement sans insister. Après sa réponse, donne un retour bref (correct / à corriger) avant de continuer."
fi

# Consume the pending edits: granular quiz once per batch, not on every stop.
: > "$STATE"

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
