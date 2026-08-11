# Bosnian does not pluralise the way English does, and by default Rails
# pretends it does.
#
# I18n's Simple backend applies one rule to every locale: `count == 1` picks
# `one`, everything else picks `other`. That is correct for English and wrong
# for Bosnian, which needs three forms — 1 soba, 2 sobe, 5 soba. Left alone, a
# receptionist in Sarajevo reads "2 soba dodano" where the language wants
# "2 sobe dodane": not a crash, just the steady wrongness of software that
# clearly had this language added last.
#
# The correct rule already ships with rails-i18n, and it is inert until the
# backend can consult a per-locale rule — which is what including this module
# does. Bosnian's effective CLDR rule asks for three forms, `one`/`few`/`other`
# (1, 21 → one; 2-4, 22-24 → few; 0, 5-20 → other). There is no `many`: CLDR
# folds it into `other` for this language, so writing one produces a key
# nothing ever reads.
#
# Consequence worth knowing before adding a counted string: a Bosnian key that
# carries only `one`/`other` does NOT raise at count 2 — measured, not assumed.
# I18n quietly falls back to `other` and renders "2 soba dodano" where the
# language wants "2 sobe dodane". That silence is the whole problem: nothing
# in the app will ever tell you, and it will read as sloppy to precisely the
# pilot customer this language exists for. test/i18n/locale_files_test.rb is
# therefore the only thing standing between a missing `few` and a hotel, and
# it checks every pluralised key in every locale family against that locale's
# own declared forms.
I18n::Backend::Simple.include(I18n::Backend::Pluralization)
