// Voice: a glass orb on the dotted grid that breathes with the microphone, the conversation in mono, and the steps
// Mycroft takes as numbered rows. GPT-Live with an OpenAI key, on-device speech without one.

import { html, useEffect, useRef } from '/lib/preact.js'
import { useData, useCall, useNavigation, Icon, Label, pad } from '../lib.js'

export function Voice() {
	const call = useCall()
	const { back } = useNavigation()
	const voice = useData((d) => d.voice)
	const end = useRef(null)

	useEffect(() => {
		call('voice.start').catch(() => {})
		return () => call('voice.stop').catch(() => {})
	}, [])
	useEffect(() => end.current?.scrollIntoView({ block: 'end' }), [voice?.lines?.length, voice?.lines?.at(-1)?.text])

	const level = voice?.level ?? 0
	let step = 0
	return html`<main class="screen voice grid">
		<header class="bar">
			<span class=${`label ${voice?.failure ? 'danger' : voice?.live ? 'soft' : 'muted'}`}>${voice?.status ?? 'Starting'}</span>
			<button class="icon-button glass" aria-label="Close" onClick=${back}><${Icon} name="close" /></button>
		</header>
		<button class=${`orb ${voice?.speaking ? 'speaking' : ''} ${voice?.live ? 'live' : ''}`} style=${`--level:${level}`}
			aria-label="Hang up" onClick=${back}>
			<span class="orb-glow"></span><span class="orb-glass glass"></span><span class="orb-mark">my</span>
		</button>
		<div class="voice-lines scroll">
			${voice?.failure && html`<p class="card danger mono small">${voice.failure}</p>`}
			${(voice?.lines ?? []).map((line) => {
				if (line.speaker === 'user') return html`<p class="voice-user"><${Label} tone="faint" size=${9}>You<//> ${line.text}</p>`
				if (line.speaker === 'mycroft') return html`<p class="voice-mycroft">${line.text}</p>`
				step += 1
				return html`<p class="voice-step"><span class="index">${pad(step)}</span>${line.text}</p>`
			})}
			<div ref=${end}></div>
		</div>
		<p class="faint small center-text gutter">Tap the orb to hang up. Work Mycroft started keeps running in the Voice thread.</p>
	</main>`
}
