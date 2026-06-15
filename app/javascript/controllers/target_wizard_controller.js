import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    // Steps
    "step",
    // Step indicator
    "indicator",
    "indicatorCircle",
    "indicatorLabel",
    "indicatorLine",
    // Provider cards (Step 1)
    "providerCard",
    // Provider badge (Step 2)
    "providerBadge",
    "providerBadgeLabel",
    // Form fields
    "targetTypeField",
    "nameField",
    "modelTypeField",
    "modelTypeSelect",
    "modelTypeSelectWrapper",
    "modelField",
    "jsonConfigField",
    "webConfigField",
    "descriptionField",
    // Conditional sections
    "apiFields",
    "webChatFields",
    "webchatNotification",
    // Review (Step 3)
    "reviewProvider",
    "reviewName",
    "reviewTargetType",
    "reviewModelType",
    "reviewModelTypeRow",
    "reviewModel",
    "reviewModelRow",
    "reviewChatUrl",
    "reviewChatUrlRow",
    "reviewDescription",
    "reviewDescriptionRow",
    "reviewConfig",
    "reviewConfigLabel",
    "reviewConfigSection",
  ];

  static values = {
    currentStep: { type: Number, default: 1 },
    selectedProvider: { type: String, default: "" },
    editing: { type: Boolean, default: false },
    templates: { type: Object, default: {} },
    errorFields: { type: Array, default: [] },
  };

  connect() {
    if (this.errorFieldsValue.length > 0) {
      this.currentStepValue = 2;
    }

    if (this.editingValue && this.currentStepValue === 1) {
      this.currentStepValue = 2;
    }

    if (this.selectedProviderValue) {
      this.toggleFieldsForProvider(this.selectedProviderValue);
      this.updateProviderBadge();
    }

    this.showStep(this.currentStepValue);
    this.updateIndicator();
  }

  // --- Step Navigation ---

  // Intentionally skips validation — used by "Edit" buttons in Step 3
  // and "Change" in Step 2 for back-navigation to previous steps.
  goToStep(event) {
    const step = parseInt(
      event.currentTarget.dataset.step || event.params?.step,
    );
    if (step >= 1 && step <= 3) {
      this.navigateToStep(step);
    }
  }

  goToStepFromIndicator(event) {
    const step = parseInt(event.currentTarget.dataset.step);
    if (step <= this.currentStepValue) {
      this.navigateToStep(step);
    }
  }

  nextStep() {
    if (!this.validateCurrentStep()) return;
    if (this.currentStepValue < 3) {
      this.navigateToStep(this.currentStepValue + 1);
    }
  }

  prevStep() {
    const minStep = this.editingValue ? 2 : 1;
    if (this.currentStepValue > minStep) {
      this.navigateToStep(this.currentStepValue - 1);
    }
  }

  navigateToStep(step) {
    this.currentStepValue = step;
    this.showStep(step);
    this.updateIndicator();

    if (step === 3) {
      this.populateReview();
    }

    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  showStep(step) {
    this.stepTargets.forEach((el) => {
      const elStep = parseInt(el.dataset.step);
      el.classList.toggle("hidden", elStep !== step);
    });
  }

  updateIndicator() {
    this.indicatorCircleTargets.forEach((circle, index) => {
      const step = index + 1;
      circle.classList.remove(
        "border-primary",
        "bg-primary/20",
        "text-primary",
        "border-borderPrimary",
        "text-contentTertiary",
      );

      const label = this.indicatorLabelTargets[index];

      if (step <= this.currentStepValue) {
        circle.classList.add("border-primary", "bg-primary/20", "text-primary");
        if (label) {
          label.classList.remove("text-contentTertiary");
          label.classList.add("text-primary");
        }
      } else {
        circle.classList.add("border-borderPrimary", "text-contentTertiary");
        if (label) {
          label.classList.remove("text-primary");
          label.classList.add("text-contentTertiary");
        }
      }
    });

    this.indicatorLineTargets.forEach((line, index) => {
      const step = index + 1;
      line.classList.remove("bg-primary", "bg-borderPrimary");
      if (step < this.currentStepValue) {
        line.classList.add("bg-primary");
      } else {
        line.classList.add("bg-borderPrimary");
      }
    });
  }

  // --- Provider Selection (Step 1) ---

  selectProvider(event) {
    const provider = event.currentTarget.dataset.provider;
    this.selectedProviderValue = provider;

    this.providerCardTargets.forEach((card) => {
      const isSelected = card.dataset.provider === provider;
      card.classList.toggle("ring-2", isSelected);
      card.classList.toggle("ring-primary", isSelected);
      card.classList.toggle("border-primary", isSelected);
    });

    if (provider === "webchat") {
      this.targetTypeFieldTarget.value = "webchat";
      this.initializeWebConfig();
    } else {
      this.targetTypeFieldTarget.value = "api";
    }

    if (
      provider !== "custom" &&
      provider !== "webchat" &&
      this.templatesValue[provider]
    ) {
      this.applyTemplate(this.templatesValue[provider]);
    } else if (provider === "custom") {
      this.clearTemplateFields();
    }

    this.toggleFieldsForProvider(provider);
    this.updateProviderBadge();
    this.navigateToStep(2);
  }

  applyTemplate(template) {
    if (this.hasNameFieldTarget)
      this.nameFieldTarget.value = template.name || "";
    if (this.hasModelTypeFieldTarget)
      this.modelTypeFieldTarget.value = template.model_type || "";
    if (this.hasModelFieldTarget)
      this.modelFieldTarget.value = template.model || "";
    if (this.hasDescriptionFieldTarget)
      this.descriptionFieldTarget.value = template.description || "";
    if (this.hasJsonConfigFieldTarget) {
      const config = template.json_config || "";
      try {
        this.jsonConfigFieldTarget.value =
          typeof config === "string" && config
            ? JSON.stringify(JSON.parse(config), null, 2)
            : config;
      } catch (error) {
        console.warn("[target-wizard] Template JSON config is malformed:", error.message);
        this.jsonConfigFieldTarget.value = config;
        this.showStepError("Template JSON configuration appears malformed. Please verify the config before proceeding.");
        this.markFieldError(this.jsonConfigFieldTarget);
      }
    }
  }

  clearTemplateFields() {
    if (this.hasNameFieldTarget) this.nameFieldTarget.value = "";
    if (this.hasModelTypeFieldTarget) this.modelTypeFieldTarget.value = "";
    if (this.hasModelTypeSelectTarget) this.modelTypeSelectTarget.value = "";
    if (this.hasModelFieldTarget) this.modelFieldTarget.value = "";
    if (this.hasDescriptionFieldTarget) this.descriptionFieldTarget.value = "";
    if (this.hasJsonConfigFieldTarget) this.jsonConfigFieldTarget.value = "";
  }

  toggleFieldsForProvider(provider) {
    const isWebchat = provider === "webchat";
    const isCustom = provider === "custom";

    if (this.hasApiFieldsTarget) {
      this.apiFieldsTarget.classList.toggle("hidden", isWebchat);
    }
    if (this.hasWebChatFieldsTarget) {
      this.webChatFieldsTarget.classList.toggle("hidden", !isWebchat);
      this.toggleWebchatRequired(isWebchat);
    }
    if (this.hasWebchatNotificationTarget) {
      this.webchatNotificationTarget.classList.toggle("hidden", !isWebchat);
    }
    if (this.hasModelTypeSelectWrapperTarget) {
      this.modelTypeSelectWrapperTarget.classList.toggle("hidden", !isCustom);
    }
  }

  toggleWebchatRequired(required) {
    if (!this.hasWebChatFieldsTarget) return;
    const fields = this.webChatFieldsTarget.querySelectorAll(
      "[data-webchat-required]",
    );
    fields.forEach((field) => {
      if (required) {
        field.setAttribute("required", "required");
      } else {
        field.removeAttribute("required");
      }
    });
  }

  syncModelType() {
    if (this.hasModelTypeSelectTarget && this.hasModelTypeFieldTarget) {
      this.modelTypeFieldTarget.value = this.modelTypeSelectTarget.value;
    }
  }

  updateProviderBadge() {
    if (!this.hasProviderBadgeLabelTarget) return;
    const template = this.templatesValue[this.selectedProviderValue];
    const specialLabels = { custom: "Custom Configuration", webchat: "Webchat" };
    this.providerBadgeLabelTarget.textContent =
      template?.name ||
      specialLabels[this.selectedProviderValue] ||
      this.selectedProviderValue;
  }

  // --- Client-side Validation ---

  validateCurrentStep() {
    this.clearValidationErrors();

    if (this.currentStepValue === 1) {
      if (!this.selectedProviderValue) {
        this.showStepError("Please select a provider to continue");
        return false;
      }
      return true;
    }

    if (this.currentStepValue === 2) {
      const errors = [];

      if (this.hasNameFieldTarget && !this.nameFieldTarget.value.trim()) {
        this.markFieldError(this.nameFieldTarget);
        errors.push("Name is required");
      }

      const isWebchat = this.selectedProviderValue === "webchat";
      const isCustom = this.selectedProviderValue === "custom";

      if (!isWebchat) {
        if (isCustom) {
          if (
            this.hasModelTypeFieldTarget &&
            !this.modelTypeFieldTarget.value
          ) {
            if (this.hasModelTypeSelectTarget) {
              this.markFieldError(this.modelTypeSelectTarget);
            }
            errors.push("Model Type is required");
          }
        }
        if (this.hasModelFieldTarget && !this.modelFieldTarget.value.trim()) {
          this.markFieldError(this.modelFieldTarget);
          errors.push("Model is required");
        }
      }

      // Validate JSON config if non-empty
      if (
        !isWebchat &&
        this.hasJsonConfigFieldTarget &&
        this.jsonConfigFieldTarget.value.trim()
      ) {
        try {
          JSON.parse(this.jsonConfigFieldTarget.value);
        } catch (e) {
          this.markFieldError(this.jsonConfigFieldTarget);
          errors.push("JSON Config contains invalid JSON");
        }
      }

      // Validate web config if webchat and non-empty
      if (
        isWebchat &&
        this.hasWebConfigFieldTarget &&
        this.webConfigFieldTarget.value.trim()
      ) {
        try {
          JSON.parse(this.webConfigFieldTarget.value);
        } catch (e) {
          this.markFieldError(this.webConfigFieldTarget);
          errors.push("Web Config contains invalid JSON");
        }
      }

      if (errors.length > 0) {
        this.showStepError(errors.join(". "));
        return false;
      }
      return true;
    }

    return true;
  }

  markFieldError(field) {
    field.classList.add("ring-2", "ring-red-500", "border-red-500");
    field.addEventListener(
      "input",
      () => {
        field.classList.remove("ring-2", "ring-red-500", "border-red-500");
      },
      { once: true },
    );
  }

  showStepError(message) {
    const currentStep = this.stepTargets.find(
      (el) => parseInt(el.dataset.step) === this.currentStepValue,
    );
    if (!currentStep) return;

    let errorEl = currentStep.querySelector("[data-wizard-step-error]");
    if (!errorEl) {
      errorEl = document.createElement("div");
      errorEl.setAttribute("data-wizard-step-error", "");
      errorEl.className = "wizard-step-error";
      currentStep.prepend(errorEl);
    }
    errorEl.textContent = message;
  }

  clearValidationErrors() {
    this.element
      .querySelectorAll("[data-wizard-step-error]")
      .forEach((el) => el.remove());
    this.element
      .querySelectorAll(".ring-red-500")
      .forEach((el) =>
        el.classList.remove("ring-2", "ring-red-500", "border-red-500"),
      );
  }

  // --- Review Population (Step 3) ---

  populateReview() {
    const isWebchat = this.selectedProviderValue === "webchat";

    if (this.hasReviewProviderTarget) {
      this.updateProviderBadge();
      this.reviewProviderTarget.textContent =
        this.providerBadgeLabelTarget.textContent;
    }

    if (this.hasReviewNameTarget && this.hasNameFieldTarget) {
      this.reviewNameTarget.textContent =
        this.nameFieldTarget.value || "(not set)";
    }

    if (this.hasReviewTargetTypeTarget) {
      this.reviewTargetTypeTarget.textContent = isWebchat ? "Webchat" : "API";
    }

    // API-specific review fields
    if (this.hasReviewModelTypeRowTarget) {
      this.reviewModelTypeRowTarget.classList.toggle("hidden", isWebchat);
    }
    if (this.hasReviewModelRowTarget) {
      this.reviewModelRowTarget.classList.toggle("hidden", isWebchat);
    }
    if (this.hasReviewModelTypeTarget) {
      const modelType = this.hasModelTypeFieldTarget
        ? this.modelTypeFieldTarget.value
        : "";
      this.reviewModelTypeTarget.textContent = modelType || "(not set)";
    }
    if (this.hasReviewModelTarget && this.hasModelFieldTarget) {
      this.reviewModelTarget.textContent =
        this.modelFieldTarget.value || "(not set)";
    }

    // Webchat-specific review fields
    if (this.hasReviewChatUrlRowTarget) {
      this.reviewChatUrlRowTarget.classList.toggle("hidden", !isWebchat);
    }
    if (this.hasReviewChatUrlTarget) {
      const urlInput = this.element.querySelector(
        'input[name="web_chat_url"]',
      );
      this.reviewChatUrlTarget.textContent =
        urlInput?.value || "(not set)";
    }

    // Description
    if (this.hasReviewDescriptionRowTarget && this.hasDescriptionFieldTarget) {
      const desc = this.descriptionFieldTarget.value.trim();
      this.reviewDescriptionRowTarget.classList.toggle("hidden", !desc);
      if (this.hasReviewDescriptionTarget) {
        this.reviewDescriptionTarget.textContent = desc;
      }
    }

    // Config (JSON or Web Config)
    if (this.hasReviewConfigTarget) {
      let config = "";
      let label = "Configuration";

      if (isWebchat && this.hasWebConfigFieldTarget) {
        config = this.webConfigFieldTarget.value;
        label = "Web Config (JSON)";
      } else if (this.hasJsonConfigFieldTarget) {
        config = this.jsonConfigFieldTarget.value;
        label = "JSON Config";
      }

      if (this.hasReviewConfigLabelTarget) {
        this.reviewConfigLabelTarget.textContent = label;
      }

      if (config.trim()) {
        try {
          this.reviewConfigTarget.textContent = JSON.stringify(
            this.redactAuthForReview(JSON.parse(config)),
            null,
            2,
          );
        } catch (error) {
          console.warn("[target-wizard] Config JSON is malformed on review:", error.message);
          // Do not dump the raw config here — it may carry auth secrets.
          this.reviewConfigTarget.textContent = "(configuration contains invalid JSON)";
        }
        if (this.hasReviewConfigSectionTarget) {
          this.reviewConfigSectionTarget.classList.remove("hidden");
        }
      } else {
        if (this.hasReviewConfigSectionTarget) {
          this.reviewConfigSectionTarget.classList.add("hidden");
        }
      }
    }
  }

  // --- Webchat Config Helpers ---

  // Replace auth credential values with non-secret summaries for the read-only
  // review so cookies/headers/storageState are never rendered in plaintext.
  redactAuthForReview(config) {
    if (!config || typeof config !== "object" || !config.auth || typeof config.auth !== "object") {
      return config;
    }
    const auth = config.auth;
    const redacted = {};
    if (Array.isArray(auth.cookies) && auth.cookies.length) {
      redacted.cookies = `${auth.cookies.length} cookie(s) [hidden]`;
    }
    if (auth.headers && typeof auth.headers === "object" && Object.keys(auth.headers).length) {
      redacted.headers = `${Object.keys(auth.headers).length} header(s) [hidden]`;
    }
    if (auth.storage_state !== undefined && auth.storage_state !== null) {
      redacted.storage_state = "[hidden]";
    }
    return { ...config, auth: redacted };
  }

  initializeWebConfig() {
    if (!this.hasWebConfigFieldTarget) return;

    const existing = this.parseWebConfig();
    if (existing && existing.url && existing.selectors) return;

    const defaultConfig = {
      url: "",
      selectors: {
        input_field: '[role="textbox"]',
        send_button: null,
        response_container: "",
        response_text: "",
      },
      wait_times: {
        page_load: 30000,
        response: 30000,
        typing_delay: 50,
      },
      detection: {
        response_message_selectors: [],
        last_message_selectors: [],
        skip_patterns: [],
        min_response_length: 5,
      },
      auth: {},
    };

    this.webConfigFieldTarget.value = JSON.stringify(defaultConfig, null, 2);
  }

  parseWebConfig() {
    if (!this.hasWebConfigFieldTarget) return null;
    try {
      const value = this.webConfigFieldTarget.value?.trim();
      return value ? JSON.parse(value) : null;
    } catch (error) {
      console.warn("[target-wizard] Web config contains invalid JSON:", error.message);
      return null;
    }
  }

  updateWebConfig(event) {
    const field = event.target.dataset.webConfigField;
    const value = event.target.value;

    try {
      const config = JSON.parse(this.webConfigFieldTarget.value || "{}");

      if (field && field.includes(".")) {
        const parts = field.split(".").filter((p) => p.length > 0);
        let obj = config;
        for (let i = 0; i < parts.length - 1; i++) {
          if (typeof obj[parts[i]] !== "object" || obj[parts[i]] === null) {
            obj[parts[i]] = {};
          }
          obj = obj[parts[i]];
        }
        obj[parts[parts.length - 1]] = value;
      } else if (field) {
        config[field] = value;
      }

      this.webConfigFieldTarget.value = JSON.stringify(config, null, 2);
    } catch (error) {
      console.warn("[target-wizard] Failed to update web config field:", field, error.message);
    }
  }
}
