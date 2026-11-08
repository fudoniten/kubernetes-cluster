#!/usr/bin/env bb

(ns cdi-nvidia-device-labeler
  (:require [clojure.string :as str]
            [cheshire.core :as json]
            [babashka.process :refer [shell]]
            [babashka.http-client :as http]
            [babashka.fs :as fs]
            [clojure.tools.cli :refer [parse-opts]])
  (:import [java.util Base64]
           [java.io FileInputStream]
           [java.security KeyStore]
           [java.security.cert CertificateFactory]
           [javax.net.ssl TrustManagerFactory SSLContext]))

(def default-kube-port 6443)

(def cli-options
  [["-H" "--hostname HOSTNAME" "The hostname of the node to label"]
   ["-d" "--device-map DEVICE_MAP" "Path to the device map JSON file"]
   ["-t" "--token TOKEN_FILE" "Path to file containing the bearer token"]
   ["-m" "--kube-master MASTER" "Kubernetes API server hostname or FQDN"]
   ["-c" "--cert CA_CERT_FILE" "Path to CA certificate file for verifying the Kubernetes API server"]
   ["-p" "--port PORT" "Kubernetes API server port"
    :default default-kube-port
    :parse-fn #(Integer/parseInt %)]
   ["-v" "--verbose" "Enable verbose output"]])

(defn log [verbose & messages]
  (when verbose (apply println messages)))

(defn usage
  ([] (usage nil))
  ([err]
   (when err (println (format "error: %s" err)))
   (println "usage: gpu-node-tagger --hostname <hostname> --device-map <device-to-labels.json> --token <token-file> --kube-master <master>")
   (System/exit 1)))

(defn process-rows [headers rows]
  (map (fn [row] (zipmap headers row)) rows))

(defn to-kebab-kw [s]
  (-> s
      (str/trim)
      (str/lower-case)
      (str/replace " " "-")
      (keyword)))

(def gpu-row-pattern
  "A data row of the CSV query: a GPU UUID first. nvidia-smi interleaves error
   lines (\"Unable to determine the device handle for GPU ...\") with the rows
   for cards it could read, so anything else on stdout is not a card."
  #"^GPU-[0-9a-fA-F-]+\s*,.*")

(defn parse-gpu-rows [out]
  (->> (str/split-lines (or out ""))
       (map str/trim)
       (filter #(re-matches gpu-row-pattern %))
       (map #(mapv str/trim (str/split % #",")))
       (process-rows [:uuid :name :memory])
       (map #(update % :name to-kebab-kw))))

(defn get-gpus
  "Query the local GPUs. Returns {:ok? bool :gpus [...]}.

   `:ok?` is false when nvidia-smi exited non-zero or could not be run. It
   can still have listed some cards: one card in a bad state fails the whole
   query, but the rows for the healthy ones are printed all the same, and
   those are kept rather than thrown away with the bad one."
  []
  (let [{:keys [exit out err]}
        (try
          (shell {:out :string :err :string :continue true}
                 (str/join " " ["nvidia-smi"
                                "--query-gpu=gpu_uuid,name,memory.total"
                                "--format=csv,noheader"]))
          (catch Exception e
            {:exit -1 :out "" :err (.getMessage e)}))
        gpus (parse-gpu-rows out)]
    (when-not (zero? exit)
      (println (format "nvidia-smi exited %d: %s" exit
                       (str/trim (str/join " " (remove str/blank? [err out]))))))
    {:ok? (zero? exit) :gpus gpus}))

(defn make-ssl-context [ca-cert-file]
  (let [cf    (CertificateFactory/getInstance "X.509")
        certs (with-open [is (FileInputStream. ca-cert-file)]
                (seq (.generateCertificates cf is)))
        ks    (KeyStore/getInstance "JKS")
        _     (.load ks nil nil)
        _     (dorun (map-indexed (fn [i c] (.setCertificateEntry ks (str "ca-" i) c)) certs))
        tmf   (doto (TrustManagerFactory/getInstance
                      (TrustManagerFactory/getDefaultAlgorithm))
                (.init ks))
        ctx   (doto (SSLContext/getInstance "TLS")
                (.init nil (.getTrustManagers tmf) nil))]
    ;; Set as JVM default so Java's HttpClient picks it up regardless of whether
    ;; babashka.http-client honours the per-request :ssl-context option.
    (SSLContext/setDefault ctx)
    ctx))

(defn get-node-labels
  "Current labels on the node, as a map of string keys to values."
  [kube-master port token hostname ca-cert-file verbose]
  (let [url  (format "https://%s:%d/api/v1/nodes/%s" kube-master port hostname)
        _    (log verbose "GET" url)
        resp (http/get url
                       {:headers     {"Authorization" (str "Bearer " token)
                                      "Accept"        "application/json"}
                        :ssl-context (make-ssl-context ca-cert-file)})]
    (-> resp :body (json/parse-string) (get-in ["metadata" "labels"]) (or {}))))

(defn patch-node! [kube-master port token hostname ca-cert-file patch verbose]
  (let [url  (format "https://%s:%d/api/v1/nodes/%s" kube-master port hostname)
        body (json/generate-string patch)]
    (log verbose "PATCH" url)
    (log verbose "Body:" body)
    (let [resp (http/patch url
                           {:headers     {"Authorization" (str "Bearer " token)
                                          "Content-Type"  "application/strategic-merge-patch+json"}
                            :body        body
                            :ssl-context (make-ssl-context ca-cert-file)})]
      (when-not (#{200 201} (:status resp))
        (println "Error patching node:" (:status resp) (:body resp))))))

(defn load-device-labels [filename]
  (-> filename slurp (json/parse-string to-kebab-kw)))

(defn parse-arguments [args]
  (let [{:keys [options errors]} (parse-opts args cli-options)]
    (if (seq errors)
      (do (doseq [e errors] (println e))
          (usage "Invalid arguments"))
      (let [{:keys [hostname device-map token kube-master cert]} options]
        (cond
          (nil? hostname)    (usage "The --hostname argument must be provided")
          (nil? device-map)  (usage "The --device-map argument must be provided")
          (nil? token)       (usage "The --token argument must be provided")
          (nil? kube-master) (usage "The --kube-master argument must be provided")
          (nil? cert)        (usage "The --cert argument must be provided")
          (not (fs/exists? device-map)) (usage (format "Device map not found: %s" device-map))
          (not (fs/exists? token))      (usage (format "Token file not found: %s" token))
          (not (fs/exists? cert))       (usage (format "CA cert file not found: %s" cert))
          :else options)))))

(def gpu-label-prefix "fudo.org/gpu.")

(defn label-patch
  "Strategic-merge label map: set every desired label to \"true\" and null out
   (i.e. delete) any existing fudo.org/gpu.* label that is no longer desired,
   so node labels never drift from the device annotation when cards change."
  [existing-labels desired-labels]
  (let [desired (set desired-labels)
        stale   (->> (keys existing-labels)
                     (filter #(str/starts-with? % gpu-label-prefix))
                     (remove desired))]
    (merge (zipmap stale (repeat nil))
           (zipmap desired (repeat "true")))))

(defn process-gpus-and-apply-labels [hostname device-map token-file kube-master port ca-cert-file verbose]
  (log verbose "Starting GPU processing and label application.")
  (let [{:keys [ok? gpus]} (get-gpus)
        _              (log verbose "GPUs found:" gpus)
        ;; Only a query that *succeeded* and listed nothing means the node has
        ;; no GPUs. A failed query with nothing readable says nothing about
        ;; the cards -- it is as often a driver not loaded yet at boot as a
        ;; card gone -- so leave the node as it is and fail the unit, where
        ;; it is visible, rather than wiping it out of the device assigner.
        _              (when (and (not ok?) (empty? gpus))
                         (println "Could not read any GPU; leaving node labels and device annotation unchanged.")
                         (System/exit 1))
        _              (when (empty? gpus)
                         (println "nvidia-smi reports no GPUs; clearing GPU labels and device annotation."))
        _              (when (and (not ok?) (seq gpus))
                         (println (format "Labelling the %d GPU(s) nvidia-smi could read; the rest are left off."
                                          (count gpus))))
        token          (str/trim (slurp token-file))
        labels         (load-device-labels device-map)
        gpu-labels     (into {} (map (fn [{:keys [uuid name]}]
                                       (when-not (contains? labels name)
                                         (println (format "warning: no label mapping for GPU model %s (%s)"
                                                          (clojure.core/name name) uuid)))
                                       [uuid (get labels name [])])
                                     gpus))
        node-labels    (if (seq gpus)
                         (distinct (map name (concat ["fudo.org/gpu.assign"]
                                                     (apply concat (vals gpu-labels)))))
                         [])
        existing       (get-node-labels kube-master port token hostname ca-cert-file verbose)
        encoder        (Base64/getEncoder)
        encoded-map    (-> gpu-labels
                           json/generate-string
                           (.getBytes "UTF-8")
                           (->> (.encodeToString encoder)))
        patch          {:metadata
                        {:labels      (label-patch existing node-labels)
                         :annotations {"fudo.org/gpu.device.labels" encoded-map}}}]
    (log verbose "Applying labels:" node-labels)
    (patch-node! kube-master port token hostname ca-cert-file patch verbose)))

(defn -main [& args]
  (let [{:keys [hostname device-map token kube-master port cert verbose]} (parse-arguments args)]
    (when hostname
      (process-gpus-and-apply-labels hostname device-map token kube-master port cert verbose))))

(apply -main *command-line-args*)
