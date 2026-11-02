<script>
	const API_URL = 'http://localhost:8000/chat';

	let question = '';
	let answer = '';
	let pageUrl = null;
	let loading = false;

	async function ask() {
		loading = true;
		answer = '';
		pageUrl = null;
		try {
			const response = await fetch(API_URL, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ question })
			});
			const data = await response.json();
			answer = data.answer;
			pageUrl = data.page_url;
		} catch (error) {
			answer = `Erreur : ${error.message}. L'API est-elle lancée ?`;
		}
		loading = false;
	}
</script>

<form on:submit|preventDefault={ask} class="flex gap-2">
	<input
		bind:value={question}
		placeholder="Ex. : compare les statistiques des légendaires par type"
		class="flex-1 border rounded px-3 py-2"
	/>
	<button disabled={loading || !question} class="border rounded px-4 py-2">
		{loading ? 'Génération…' : 'Générer'}
	</button>
</form>

{#if answer}
	<p class="mt-4">{answer}</p>
{/if}

{#if pageUrl}
	<p><a href={pageUrl} class="underline">Ouvrir le tableau de bord</a></p>
	<iframe src={pageUrl} title="Tableau de bord généré" class="w-full h-[800px] border rounded mt-2" />
{/if}
