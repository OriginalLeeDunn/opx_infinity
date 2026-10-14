--- Player-facing text owned by the form module.
-- @author dop42
--
-- The key caps under the fields, and the four refusals this module writes on
-- the status line itself. Every other string a form draws is the caller's own.

OPX.Locale.Register('en', {
	['form.key.field'] = 'Switch field',
	['form.key.edit'] = 'Type to edit',
	['form.key.change'] = 'Change',
	['form.key.confirm'] = 'Confirm',
	['form.key.cancel'] = 'Cancel',
	['form.eyebrow'] = 'FORM',

	['form.refuse.required'] = 'This field cannot be left empty.',
	['form.refuse.format'] = 'That is not a value this field accepts.',
	['form.refuse.character'] = 'That character is not accepted here.',
	['form.refuse.tooLong'] = 'This field takes at most {max} characters.',
})

OPX.Locale.Register('fr', {
	['form.key.field'] = 'Changer de champ',
	['form.key.edit'] = 'Saisir',
	['form.key.change'] = 'Changer',
	['form.key.confirm'] = 'Valider',
	['form.key.cancel'] = 'Annuler',
	['form.eyebrow'] = 'FORMULAIRE',

	['form.refuse.required'] = 'Ce champ ne peut pas rester vide.',
	['form.refuse.format'] = "Cette valeur n'est pas acceptée ici.",
	['form.refuse.character'] = "Ce caractère n'est pas accepté ici.",
	['form.refuse.tooLong'] = 'Ce champ accepte au plus {max} caractères.',
})
