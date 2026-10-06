// Run inside the pinned Pingvin image with the generated email service mounted.
const assert = require("node:assert/strict");
const { createRequire } = require("node:module");
const { test } = require("node:test");
const requireApp = createRequire("/opt/app/backend/package.json");
const { EmailService } = requireApp("./dist/src/email/email.service.js");
const moment = requireApp("moment");

function fixture() {
  const config = {
    "share.enableShareEmailRecipients": true,
    "general.appUrl": "https://transfer.example.org",
    "general.appName": "ZuidWest Transfer",
    "general.defaultLanguage": "nl-BE",
    "email.shareRecipientsReplyToCreator": true,
    "email.shareRecipientsSubject": "Bestanden van {creator} voor {name}",
    "email.shareRecipientsMessage": "De link verloopt {expires}{descBlock}",
    "email.sendHtmlEmails": false,
    "smtp.email": "transfer@example.org",
  };
  const translations = {
    "email.locale": "nl-BE",
    "email.shareRecipientsCreatorFallback": "Iemand",
    "email.shareRecipientsDescFallback": "Geen beschrijving",
    "email.shareRecipientsExpiresNeverFallback": "in: nooit",
  };
  const translate = (key) => {
    assert.ok(Object.hasOwn(translations, key), `Unexpected translation: ${key}`);
    return translations[key];
  };
  const service = new EmailService({ get: (key) => config[key] }, {
    t: translate,
    translate,
  });
  let mail;
  service.getTransporter = () => ({ sendMail: async (value) => { mail = value; } });
  const creator = {
    username: "raymon",
    displayName: "Raymon Mens",
    email: "sender@example.org",
  };
  return {
    config,
    async render(description, expiration = new Date(0), sender = creator) {
      await service.sendMailToShareRecipients(
        "recipient@example.org", "recipient+id", "share-id", sender,
        description, expiration, "Ontvanger",
      );
      return mail;
    },
  };
}

test("missing or blank descriptions omit the optional sentence", async () => {
  const { render } = fixture();
  for (const description of [undefined, null, "", "   ", "\n\t", "..."]) {
    assert.equal((await render(description)).text, "De link verloopt nooit.");
  }
});

test("filled descriptions keep the existing wording and punctuation", async () => {
  const { render } = fixture();
  for (const description of ["Hier zijn de bestanden", "  Hier zijn de bestanden...  "]) {
    assert.equal((await render(description)).text,
      'De link verloopt nooit en dit bericht werd toegevoegd: "Hier zijn de bestanden".');
  }
  assert.equal((await render('Gebruik {expires} en "$&".')).text,
    'De link verloopt nooit en dit bericht werd toegevoegd: "Gebruik {expires} en "$&"".');
});

test("finite expiry remains Dutch, with and without a description", async () => {
  const { render } = fixture();
  const expiration = moment().add(7, "days").toDate();
  assert.equal((await render(undefined, expiration)).text, "De link verloopt over 7 dagen.");
  assert.equal((await render("Bekijk deze bestanden", expiration)).text,
    'De link verloopt over 7 dagen en dit bericht werd toegevoegd: "Bekijk deze bestanden".');
});

test("upstream template variables, fallbacks and addressing remain intact", async () => {
  const { config, render } = fixture();
  config["email.shareRecipientsMessage"] = "{desc}|{creatorEmail}|{shareUrl}|{recipient}|{recipientEmail}|{email}";
  const mail = await render("Originele tekst.");
  assert.equal(mail.subject, "Bestanden van Raymon Mens voor Ontvanger");
  assert.equal(mail.text, "Originele tekst.|sender@example.org|https://transfer.example.org/s/share-id?recipient=recipient%2Bid|Ontvanger|recipient@example.org|recipient@example.org");
  assert.deepEqual(mail.from, { name: "ZuidWest Transfer", address: "transfer@example.org" });
  assert.deepEqual(mail.to, { name: "Ontvanger", address: "recipient@example.org" });
  assert.deepEqual(mail.replyTo, { name: "Raymon Mens", address: "sender@example.org" });
  config["email.shareRecipientsMessage"] = "{creator}|{desc}";
  const fallback = await render(null, new Date(0), null);
  assert.equal(fallback.text, "Iemand|Geen beschrijving");
  assert.equal(fallback.replyTo, undefined);
});
