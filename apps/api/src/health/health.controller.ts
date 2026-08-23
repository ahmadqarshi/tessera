import { Controller, Get } from "@nestjs/common";
import { PrismaService } from "../prisma/prisma.service";

interface HealthResponse {
  status: "ok" | "degraded";
  uptimeSeconds: number;
  checks: { database: "up" | "down" };
}

@Controller("health")
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async check(): Promise<HealthResponse> {
    let database: "up" | "down" = "down";
    try {
      await this.prisma.$queryRaw`SELECT 1`;
      database = "up";
    } catch {
      database = "down";
    }
    return {
      status: database === "up" ? "ok" : "degraded",
      uptimeSeconds: Math.floor(process.uptime()),
      checks: { database },
    };
  }
}
