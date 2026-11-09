# Instrukce pro agenty — MoneyApp

## Kontext a rozsah

Tento projekt je nativní macOS aplikace ve Swiftu a SwiftUI pro osobní finance. Produktový plán a stav práce jsou v `PLAN.md`. Složka byla při zahájení prázdná. Pravidla původního bi-net-v2 monorepa pro React, NestJS, pnpm a @bi balíčky nejsou technologickými konvencemi tohoto projektu.

Nejprve upřesni zadání, maximálně třemi otázkami najednou. Aplikační kód piš až po odsouhlasení směru. Nové bankovní napojení, cloud, server a změny rozsahu domluv s uživatelem. Schválené rutinní kroky nevyžadují opakované potvrzování.

## Pracovní postup

1. Přečti plán a relevantní existující kód. Před novou funkcí hledej existující řešení pomocí `rg`; logiku neduplikuj.
2. U netriviální změny stručně popiš postup. U významných alternativ ukaž praktické trade-offy a doporučení.
3. Pracuj v malých funkčních celcích, průběžně ověřuj a aktualizuj checkboxy v plánu.
4. Neměň nesouvisející soubory a nevracej změny uživatele. Neloguj osobní finanční data ani secrets.
5. Při předání popiš výsledek, ověření a skutečná omezení. Netvrď, že build/test prošel, pokud neběžel.

## Delegování a náklady

- Hlavní agent odpovídá za návrh, integraci, review a konečný výsledek.
- Pro menší ohraničené úkoly používej dostupný úspornější model, výchozí volba `gpt-5.6-luna` s nízkým reasoningem. U obtížného úkolu zvaž vyšší reasoning nebo práci hlavního agenta. Relativní cenu nepovažuj za zaručenou bez aktuálních údajů.
- Deleguj pouze nezávislé úkoly, pokud zároveň může hlavní agent užitečně pokračovat. Nezakládej agenta pro každý drobný krok.
- Předávej stručný kontext (`fork_turns: none`), konkrétní výstup, povolené soubory, omezení a způsob validace. Nenech dva agenty měnit tentýž soubor.
- Subagent nesmí měnit produktový rozsah, rozhodovat otevřené požadavky ani dále delegovat bez konkrétního zadání hlavního agenta.
- Po delegování přečti výsledek i diff, prověř correctness, duplicity, bezpečnost, finanční invariants a relevantní testy. Report subagenta není důkaz úspěšného ověření.
- Používej krátké věcné reporty. Neposílej celý repozitář ani dlouhé výpisy, pokud stačí konkrétní soubory a symboly.

## Architektura a kvalita

- Přiměřená Clean Architecture: finanční model a pravidla nezávisí na SwiftUI ani konkrétním úložišti. Aplikační vrstva koordinuje případy použití; infrastructure řeší disk/import/export; UI prezentuje stav a uživatelské akce.
- Strukturu drž jednoduchou v jednom app targetu, dokud nevznikne konkrétní potřeba dalších modulů. Nepřidávej framework pro DI, generické repository ani protokol pro každý typ jen kvůli architektuře.
- SOLID, DRY, KISS a YAGNI používej prakticky: malé odpovědnosti, explicitní závislosti, rozhraní na skutečných hranicích. Sdílej výpočty mezi dashboardem, seznamem a exportem.
- SwiftUI views neobsahují finanční výpočty, parsování importu ani přímé souborové operace. Stav UI měň na odpovídajícím actoru; neblokuj hlavní vlákno importem ani diskovou prací.
- Používej idiomatické Swift API podle potvrzeného deployment targetu; nevnucuj webové ani backendové CQRS/DDD vzory.
- Chyby předávej srozumitelně do UI; nepolykej je pomocí prázdného catch nebo neodůvodněného `try?`. Vyhýbej se force unwrapům.

## Finanční správnost a data

- Peníze nereprezentuj ani nepočítej přes `Double`/`Float`. Zvol a zdokumentuj přesnou reprezentaci (`Decimal` nebo integer minor units), pravidla zaokrouhlování a bezpečné ukládání bez ztráty přesnosti.
- Každá částka má měnu. Částky různých měn nesčítej bez explicitního pravidla převodu a zaznamenaného kurzu. Konverze pro graf nesmí být zdrojem finančního součtu.
- Převody mezi vlastními účty nesmějí navyšovat příjmy a výdaje. Změny obou stran převodu musí být konzistentní při vytvoření, úpravě i odstranění.
- Odděl datum transakce od technických timestampů a definuj kalendářní hranice období.
- Import musí mít validaci a jasné chování pro duplicity a částečné chyby. Nevytvářej duplicity při opakování stejného importu.
- Ukládej lokálně; návrh persistence musí řešit migrace, chyby zápisu, zálohu i obnovu. Nezaváděj vlastní kryptografii.
- Ukázková data patří do odděleného preview/demo úložiště. Nikdy je tiše nemíchej s uživatelskými daty.
- Tvrzení o úsporách odvozuj z dohledatelných dat. Uveď období a výpočet; odhad označ a nedostatek historie přiznej.

## UI a ověřování

- Nativní SwiftUI ovládací prvky a macOS konvence, české texty, locale-aware částky a data, světlý/tmavý vzhled, klávesnice a VoiceOver.
- Řeš loading, empty, error, validaci formulářů a feedback po akcích. Destruktivní akce mají přiměřenou ochranu nebo možnost vrácení.
- Testuj skutečné business rules: přesnost, součty, převody, období, případný import a zálohu/obnovu. Netestuj pouhé zapojení frameworku ani kopii implementace.
- Po změně proveď dostupný build a cílené testy. Nástroje a příkazy stanov až podle projektu; webové `pnpm lint:fix` a `pnpm format` se na čistý Swift projekt nevztahují.

## Konkrétní projekt a kontroly

Směr byl uživatelem schválen. SwiftPM používá targety `MoneyCore` (nezávisle testovatelná pravidla + SQLite adaptér) a `MoneyApp` (SwiftUI + koordinace). Nezaváděj další vrstvy bez konkrétní potřeby.

- Build: `swift build`; testy: `swift test`.
- Formát: `swift format format --in-place --recursive Sources Tests Package.swift scripts/make-icon.swift`.
- Kontrola formátu: `swift format lint --strict --recursive Sources Tests Package.swift scripts/make-icon.swift`.
- Aplikace: `bash scripts/build-app.sh` → `build/MoneyApp.app`.
- UI testy prováděj výhradně s `--demo`, který vytvoří oddělenou dočasnou databázi. Do běžného osobního úložiště nezapisuj testovací finance.
- Při práci více agentů nespouštěj finální build/test, dokud nedokončí zápisy do příslušných souborů. Před formátováním počkej na dokončení jejich editací.
- Financial read dotazy předpokládají validovaný snapshot. Validuj na hranici načtení, obnovení a mutace; neopakuj celou validaci při každé položce grafu.
