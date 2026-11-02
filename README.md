# sql-dashboard-agent-pokemon

## Assistant de tableaux de bord

Une page de chat (`/chat`) génère un tableau de bord Evidence à partir d'une question.

```bash
export ANTHROPIC_API_KEY=...
.venv/bin/uvicorn src.agent_api:app --port 8000   # API de l'agent
cd dashboard && npm run dev                       # puis ouvrir http://localhost:3000/chat
```

Les pages générées sont écrites dans `dashboard/pages/generated/` (ignoré par git) et ne s'affichent qu'en mode dev.
