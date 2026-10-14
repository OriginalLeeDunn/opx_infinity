--- Player-facing text owned by the chat module.
-- @author dop42
--
-- Everything a view draws comes from here, already rendered: a view has no
-- catalogue of its own. Log lines stay in English.

OPX.Locale.Register('en', {
	['chat.tooManyArgs'] = 'Commands are limited to {max} arguments.',
	['chat.escapeAtEnd'] = 'A command cannot end with an escape character.',
	['chat.unterminatedQuote'] = 'The command contains an unterminated quote.',
	['chat.commandExpected'] = "Enter a command after '/'.",

	['chat.commandNotSent'] = 'The command could not be sent.',
	-- The keycaps on the input line: the words printed on the player's own keyboard.
	['chat.key.tab'] = 'Tab',
	['chat.key.enter'] = 'Enter',
	['chat.key.escape'] = 'Esc',
	['chat.messageNotSent'] = 'The message could not be sent.',
	['chat.tooFast'] = 'That message was not sent: wait a moment between two.',
	['chat.notLoaded'] = 'That message was not sent: you speak once your character is in the city.',

	['chat.command.unknown'] = '/{command} is not a command on this server.',
	['chat.command.denied'] = 'You are not allowed to run /{command}.',
	['chat.command.tooFast'] = 'Slow down: wait a moment before running that again.',
	['chat.command.failed'] = '/{command} could not be run.',

	['chat.author.command'] = 'COMMAND',
	['chat.author.network'] = 'NETWORK',
	-- A player's line is signed with their server id, never a name: never a name
	-- to a stranger.
	['chat.author.player'] = 'Player #{id}',

	['chat.placeholder'] = 'Say something, or type / for a command',

	-- The name the pause menu's shortcuts tab lists the open key under.
	['chat.key.open'] = 'Open the chat',

	['chat.invalidMessage'] = 'That message could not be read.',
	['chat.noView'] = 'The chat box is not drawn yet.',
	['chat.invalidKind'] = 'That is not a kind of chat line.',
	['chat.noPlayer'] = 'Nobody is connected under that id.',
	['chat.invalidScope'] = 'That broadcast names no place it could reach.',
	['chat.invalidCommand'] = 'That command name could not be read.',
})

OPX.Locale.Register('fr', {
	['chat.tooManyArgs'] = 'Les commandes sont limitées à {max} arguments.',
	['chat.escapeAtEnd'] = "Une commande ne peut pas finir par un caractère d'échappement.",
	['chat.unterminatedQuote'] = 'La commande contient un guillemet non fermé.',
	['chat.commandExpected'] = "Saisissez une commande après le '/'.",

	['chat.commandNotSent'] = "La commande n'a pas pu être envoyée.",
	['chat.key.tab'] = 'Tab',
	['chat.key.enter'] = 'Entrée',
	['chat.key.escape'] = 'Échap',
	['chat.messageNotSent'] = "Le message n'a pas pu être envoyé.",
	['chat.tooFast'] = "Ce message n'a pas été envoyé : attendez un instant entre deux.",
	['chat.notLoaded'] = "Ce message n'a pas été envoyé : vous parlez une fois votre personnage en ville.",

	['chat.command.unknown'] = "/{command} n'est pas une commande de ce serveur.",
	['chat.command.denied'] = "Vous n'avez pas le droit de lancer /{command}.",
	['chat.command.tooFast'] = 'Doucement : attendez un instant avant de relancer cette commande.',
	['chat.command.failed'] = "/{command} n'a pas pu être lancée.",

	['chat.author.command'] = 'COMMANDE',
	['chat.author.network'] = 'RÉSEAU',
	['chat.author.player'] = 'Joueur #{id}',

	['chat.placeholder'] = 'Dites quelque chose, ou tapez / pour une commande',

	['chat.key.open'] = 'Ouvrir le chat',

	['chat.invalidMessage'] = "Ce message n'a pas pu être lu.",
	['chat.noView'] = "La boîte de chat n'est pas encore dessinée.",
	['chat.invalidKind'] = "Ce n'est pas un type de ligne de chat.",
	['chat.noPlayer'] = "Personne n'est connecté sous cet identifiant.",
	['chat.invalidScope'] = "Cette diffusion ne désigne aucun endroit qu'elle puisse atteindre.",
	['chat.invalidCommand'] = "Ce nom de commande n'a pas pu être lu.",
})
