require "securerandom"
require "kubeclient"

module Resque
  module Kubernetes
    module Job

      def before_enqueue_kubernetes_job(*_)
        if defined? Rails
          return unless Resque::Kubernetes.environments.include?(Rails.env)
        end

        reap_finished_jobs
        reap_finished_pods
        apply_kubernetes_job
      end

      private

      def jobs_client
        return @jobs_client if @jobs_client
        @jobs_client = client("/apis/batch")
      end

      def pods_client
        return @pods_client if @pods_client
        @pods_client = client("")
      end

      def client(scope)
        kubeconfig = File.join(ENV["HOME"], ".kube", "config")
        # TODO: Add ability to load this from config
        context = nil

        if File.exist?("/var/run/secrets/kubernetes.io/serviceaccount/token")
          # When running in GKE/k8s cluster, use the service account secret token and ca bundle
          context = Kubeclient::Config::Context.new(
              "https://kubernetes",
              "v1",
              {ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"},
              {bearer_token_file: "/var/run/secrets/kubernetes.io/serviceaccount/token"}
          )
        elsif File.exist?(kubeconfig)
          # When running in development, use the config file for `kubectl` and default application credentials
          kubeconfig = File.join(ENV["HOME"], ".kube", "config")
          config     = Kubeclient::Config.read(kubeconfig)
          context    = Kubeclient::Config::Context.new(
              config.context.api_endpoint,
              config.context.api_version,
              config.context.ssl_options,
              {use_default_gcp: true}
          )
        end

        if context
          Kubeclient::Client.new(
              context.api_endpoint + scope,
              context.api_version,
              ssl_options: context.ssl_options,
              auth_options: context.auth_options,
          )
        end
      end

      def reap_finished_jobs
        resque_jobs = jobs_client.get_jobs(label_selector: "resque-kubernetes=job")
        finished = resque_jobs.select { |job| job.spec.completions == job.status.succeeded }

        finished.each do |job|
          begin
            jobs_client.delete_job(job.metadata.name, job.metadata.namespace)
          rescue
            puts "Cannot Delete Job"
          end
        end
      end

      def reap_finished_pods
        resque_jobs = pods_client.get_pods(label_selector: "resque-kubernetes=pod")
        finished = resque_jobs.select { |pod| pod.status.phase == "Succeeded" }

        finished.each do |pod|
          begin
            pods_client.delete_pod(pod.metadata.name, pod.metadata.namespace)
          rescue
            puts "Cannot Delete Pod"
          end
        end
      end

      def apply_kubernetes_job
        puts "Pulling Manifest for #{self.inspect}"
        manifest = job_manifest.dup
        ensure_namespace(manifest)

        # Do not start job if we have reached our maximum count
        return if jobs_maxed?(manifest["metadata"]["name"], manifest["metadata"]["namespace"])

        add_labels(manifest)
        ensure_term_on_empty(manifest)
        ensure_reset_policy(manifest)
        #update_job_name(manifest)

        job = Kubeclient::Resource.new(manifest)
        puts "Creating Job"
        response = jobs_client.create_job(job)
        puts "Job Created"
        return true
      end

      def jobs_maxed?(name, namespace)
        resque_jobs = jobs_client.get_jobs(label_selector: "resque-kubernetes=job,resque-kubernetes-group=#{name}", namespace: namespace)
        running = resque_jobs.select { |job| job.spec.completions != job.status.succeeded }
        running.size == Resque::Kubernetes.max_workers
      end

      def add_labels(manifest)
        manifest["metadata"] ||= {}
        manifest["metadata"]["labels"] ||= {}
        manifest["metadata"]["labels"]["resque-kubernetes"] = "job"
        manifest["metadata"]["labels"]["resque-kubernetes-group"] = manifest["metadata"]["name"]
        manifest["spec"]["template"]["metadata"] ||= {}
        manifest["spec"]["template"]["metadata"]["labels"] ||= {}
        manifest["spec"]["template"]["metadata"]["labels"]["resque-kubernetes"] = "pod"
      end

      def ensure_term_on_empty(manifest)
        manifest["spec"]["template"]["spec"] ||= {}
        manifest["spec"]["template"]["spec"]["containers"] ||= []
        manifest["spec"]["template"]["spec"]["containers"].each do |container|
          container["env"] ||= []
          term_on_empty = container["env"].find { |env| env["name"] == "TERM_ON_EMPTY" }
          unless term_on_empty
            term_on_empty = {"name" => "TERM_ON_EMPTY"}
            container["env"] << term_on_empty
          end
          term_on_empty["value"] = "1"
        end
      end

      def ensure_reset_policy(manifest)
        manifest["spec"]["template"]["spec"]["restartPolicy"] ||= "OnFailure"
      end


      def ensure_namespace(manifest)
        manifest["metadata"]["namespace"] ||= "default"
      end

      def update_job_name(manifest)
        manifest["metadata"]["name"] += "-#{dns_safe_random}"
      end

      # Returns an n-length string of characters [a-z0-9]
      def dns_safe_random(n = 5)
        s = [SecureRandom.random_bytes(n)].pack("m*")
        s.delete!("=\n")
        s.tr!("+/_-", "0")
        s.tr!("A-Z", "a-z")
        s[0...n]
      end

    end
  end
end
