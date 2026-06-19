"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};
var EmailService_1;
Object.defineProperty(exports, "__esModule", { value: true });
exports.EmailService = void 0;
const common_1 = require("@nestjs/common");
const moment = require("moment");
const nodemailer = require("nodemailer");
const nestjs_i18n_1 = require("nestjs-i18n");
const config_service_1 = require("../config/config.service");
let EmailService = EmailService_1 = class EmailService {
    constructor(config, i18n) {
        this.config = config;
        this.i18n = i18n;
        this.logger = new common_1.Logger(EmailService_1.name);
    }
    getTransporter() {
        if (!this.config.get("smtp.enabled"))
            throw new common_1.InternalServerErrorException(this.i18n.t("email.smtpDisabled"));
        const username = this.config.get("smtp.username");
        const password = this.config.get("smtp.password");
        return nodemailer.createTransport({
            host: this.config.get("smtp.host"),
            port: this.config.get("smtp.port"),
            secure: this.config.get("smtp.port") == 465,
            auth: username || password ? { user: username, pass: password } : undefined,
            tls: {
                rejectUnauthorized: !this.config.get("smtp.allowUnauthorizedCertificates"),
            },
        });
    }
    async sendMail(email, subject, text) {
        await this.getTransporter()
            .sendMail({
            from: `"${this.config.get("general.appName")}" <${this.config.get("smtp.email")}>`,
            to: email,
            subject,
            text,
        })
            .catch((e) => {
            this.logger.error(e);
            throw new common_1.InternalServerErrorException(this.i18n.t("email.sendFailed"));
        });
    }
    async sendMailToShareRecipients(recipientEmail, recipientId, shareId, creator, description, expiration) {
        if (!this.config.get("email.enableShareEmailRecipients"))
            throw new common_1.InternalServerErrorException(this.i18n.t("email.emailServiceDisabled"));
        const shareUrl = `${this.config.get("general.appUrl")}/s/${shareId}?recipient=${encodeURIComponent(recipientId)}`;
        const lang = this.config.get("general.defaultLanguage");
        const locale = this.i18n.translate("email.locale", { lang });
        const trimmedDesc = (description ?? "").trim().replace(/\.+$/, "");
        const descBlock = trimmedDesc ? ` en dit bericht werd toegevoegd: "${trimmedDesc}".` : ".";
        await this.sendMail(recipientEmail, this.config.get("email.shareRecipientsSubject"), this.config
            .get("email.shareRecipientsMessage")
            .replaceAll("\\n", "\n")
            .replaceAll("{creator}", creator?.username ??
            this.i18n.t("email.shareRecipientsCreatorFallback"))
            .replaceAll("{creatorEmail}", creator?.email ?? "")
            .replaceAll("{shareUrl}", shareUrl)
            .replaceAll("{desc}", description ?? this.i18n.t("email.shareRecipientsDescFallback"))
            .replaceAll("{descBlock}", descBlock)
            .replaceAll("{expires}", moment(expiration).unix() != 0
            ? moment(expiration).locale(locale).fromNow()
            : "nooit"));
    }
    async sendShareDownloadNotification(creatorEmail, shareId, fileName, recipientEmail) {
        const shareUrl = `${this.config.get("general.appUrl")}/s/${shareId}`;
        await this.sendMail(creatorEmail, this.config.get("email.shareDownloadNotificationSubject"), this.config
            .get("email.shareDownloadNotificationMessage")
            .replaceAll("\\n", "\n")
            .replaceAll("{recipientEmail}", recipientEmail)
            .replaceAll("{fileName}", fileName)
            .replaceAll("{shareUrl}", shareUrl));
    }
    async sendMailToReverseShareCreator(recipientEmail, shareId) {
        const shareUrl = `${this.config.get("general.appUrl")}/s/${shareId}`;
        await this.sendMail(recipientEmail, this.config.get("email.reverseShareSubject"), this.config
            .get("email.reverseShareMessage")
            .replaceAll("\\n", "\n")
            .replaceAll("{shareUrl}", shareUrl));
    }
    async sendResetPasswordEmail(recipientEmail, token) {
        const resetPasswordUrl = `${this.config.get("general.appUrl")}/auth/resetPassword/${token}`;
        await this.sendMail(recipientEmail, this.config.get("email.resetPasswordSubject"), this.config
            .get("email.resetPasswordMessage")
            .replaceAll("\\n", "\n")
            .replaceAll("{url}", resetPasswordUrl));
    }
    async sendInviteEmail(recipientEmail, password) {
        const loginUrl = `${this.config.get("general.appUrl")}/auth/signIn`;
        await this.sendMail(recipientEmail, this.config.get("email.inviteSubject"), this.config
            .get("email.inviteMessage")
            .replaceAll("{url}", loginUrl)
            .replaceAll("{password}", password)
            .replaceAll("{email}", recipientEmail));
    }
    async sendVerificationEmail(recipientEmail, token) {
        const verificationUrl = `${this.config.get("general.appUrl")}/auth/verify/${token}`;
        await this.sendMail(recipientEmail, this.config.get("email.verificationSubject"), this.config
            .get("email.verificationMessage")
            .replaceAll("\\n", "\n")
            .replaceAll("{url}", verificationUrl));
    }
    async sendTestMail(recipientEmail) {
        const subject = this.i18n.t("email.testSubject");
        const text = this.i18n.t("email.testText");
        await this.getTransporter()
            .sendMail({
            from: `"${this.config.get("general.appName")}" <${this.config.get("smtp.email")}>`,
            to: recipientEmail,
            subject,
            text,
        })
            .catch((e) => {
            this.logger.error(e);
            throw new common_1.InternalServerErrorException(e.message);
        });
    }
};
exports.EmailService = EmailService;
exports.EmailService = EmailService = EmailService_1 = __decorate([
    (0, common_1.Injectable)(),
    __metadata("design:paramtypes", [config_service_1.ConfigService,
        nestjs_i18n_1.I18nService])
], EmailService);
//# sourceMappingURL=email.service.js.map