// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const repo = 'https://github.com/general-intelligence-systems/brute';

// https://astro.build/config
export default defineConfig({
	site: 'https://general-intelligence-systems.github.io',
	base: '/brute',
	trailingSlash: 'always',
	integrations: [
		starlight({
			title: 'brute',
			description:
				'A framework-agnostic coding agent for Ruby. Rack-style middleware pipelines for agent turns, built-in tools, session persistence — bring your own LLM library.',
			social: [{ icon: 'github', label: 'GitHub', href: repo }],
			editLink: { baseUrl: `${repo}/edit/trench/docs/` },
			lastUpdated: true,
			customCss: ['./src/styles/custom.css'],
			components: {
				// Adds the "Copy page as Markdown" control above each page title.
				PageTitle: './src/components/PageTitle.astro',
			},
			// Slugs are flat so the URLs match the previous Jekyll site exactly
			// (its collections used a `/:name/` permalink).
			sidebar: [
				{
					label: 'Start Here',
					items: [{ label: 'Getting Started', slug: 'getting-started' }],
				},
				{
					label: 'Core Features',
					items: [
						{ label: 'The Agent Pipeline', slug: 'agents' },
						{ label: 'Messages', slug: 'messages' },
						{ label: 'Message Transports', slug: 'message-transports' },
						{ label: 'Tools', slug: 'tools' },
						{ label: 'Middleware', slug: 'middleware' },
					],
				},
				{
					label: 'Advanced',
					items: [
						{ label: 'Sub-Agents', slug: 'sub-agents' },
						{ label: 'Sessions', slug: 'sessions' },
						{ label: 'Skills', slug: 'skills' },
						{ label: 'Events', slug: 'events' },
						{ label: 'Serving over HTTP', slug: 'rack' },
					],
				},
				{
					label: 'Examples',
					items: [{ label: 'Runnable Examples', slug: 'examples' }],
				},
			],
		}),
	],
});
