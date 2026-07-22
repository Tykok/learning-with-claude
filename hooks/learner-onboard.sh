#!/bin/sh
# Part of "learning mode" (see learner-record-edit.sh / learner-quiz.sh).
#
# SessionStart hook: if the learner has not declared a level yet, inject context
# asking Claude to prompt the user for it at the start of the conversation and to
# create .claude/learner.local.json once answered. No-op once a valid level exists.
# Wired as a SessionStart hook; see .claude/settings.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
LEVEL_FILE="$PROJECT_DIR/.claude/learner.local.json"

# Already configured with a valid level -> nothing to do.
if [ -f "$LEVEL_FILE" ]; then
  LEVEL=$(jq -r '.level // empty' "$LEVEL_FILE" 2>/dev/null)
  [ -n "$LEVEL" ] && exit 0
fi

CTX="Le « mode apprentissage » de ce projet n'est pas encore configuré (aucun niveau déclaré dans .claude/learner.local.json). \
Tout au début de ta prochaine réponse à l'utilisateur, AVANT de traiter sa demande, configure-le en lui posant des questions (idéalement via l'outil de questions à choix) : \
1) son NIVEAU sur ce codebase — junior, intermediaire ou senior (obligatoire) ; \
2) s'il veut personnaliser les options ou garder les défauts. Options et défauts : \
enabled (défaut true) = activer les questions ; \
recapEvery (défaut 3) = une question de synthèse tous les N quiz ; \
questionStyles (défaut \"auto\") = formats autorisés parmi code / trou / archi, ou \"auto\" (tu choisis) ; \
language (défaut \"fr\") = langue des questions, fr ou en ; \
trouBlanks (défaut 2) = nombre de trous // TODO laissés au dev en style trou ; \
trackGlobs (défaut sources multi-langages, voir learner.local.json.example) = types de fichiers édités pris en compte pour les questions. \
Deux fichiers gitignored sont tenus automatiquement : .claude/learner-memory.md (mémoire de travail du quiz, points faibles) et .claude/learner-recap.md (tableau de bord lisible : à améliorer, acquis, historique des sessions). \
Dès qu'il a répondu, crée .claude/learner.local.json avec un JSON contenant level + les options (défauts pour celles qu'il ne personnalise pas), par ex. \
{\"level\":\"junior\",\"enabled\":true,\"recapEvery\":3,\"questionStyles\":\"auto\",\"language\":\"fr\"}. \
Confirme brièvement puis enchaîne sur sa demande initiale. \
S'il refuse ou dit d'ignorer, n'insiste pas et ne crée pas le fichier — mais préviens-le qu'aucune question ne se déclenchera tant que le niveau n'est pas renseigné."

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
